# Sobe um PostgreSQL descartável, instala o guarda e roda o teste de aceitação.
#
# Serve para validar o sistema sem tocar em nenhum banco da empresa. O
# cluster vai para uma pasta temporária e é derrubado no fim, a menos que
# você passe -Manter.
#
#   .\ferramentas\postgres-local.ps1
#   .\ferramentas\postgres-local.ps1 -Manter          # deixa o servidor no ar
#   .\ferramentas\postgres-local.ps1 -Porta 55555
#
# Precisa dos binários do PostgreSQL. Se não tiver:
#   scoop install postgresql

param(
    [int]    $Porta = 55432,
    [string] $PastaBin = "",
    [string] $Banco = "lojateste",
    [switch] $Manter
)

$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# --- localizar os binários -------------------------------------------------
if (-not $PastaBin) {
    $candidatos = @()
    $candidatos += (Get-ChildItem "$env:USERPROFILE\scoop\apps\postgresql" -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName "bin" })
    $candidatos += (Get-ChildItem "C:\Program Files\PostgreSQL" -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName "bin" })

    $PastaBin = $candidatos | Where-Object { Test-Path (Join-Path $_ "initdb.exe") } | Select-Object -First 1
}

if (-not $PastaBin -or -not (Test-Path (Join-Path $PastaBin "initdb.exe"))) {
    Write-Error "Nao encontrei os binarios do PostgreSQL. Instale com 'scoop install postgresql' ou passe -PastaBin."
}

$initdb   = Join-Path $PastaBin "initdb.exe"
$pgctl    = Join-Path $PastaBin "pg_ctl.exe"
$psql     = Join-Path $PastaBin "psql.exe"
$pgisready = Join-Path $PastaBin "pg_isready.exe"

Write-Host "usando $PastaBin" -ForegroundColor DarkGray

# --- criar o cluster -------------------------------------------------------
$base   = Join-Path $env:TEMP ("guarda-teste-" + $Porta)
$dados  = Join-Path $base "pgdata"
$log    = Join-Path $base "servidor.log"

# Se ja tem algo escutando nessa porta, para aqui. Duas execucoes na mesma
# porta compartilhariam a pasta de dados e uma derrubaria a outra pela metade.
& $pgisready -h 127.0.0.1 -p $Porta -q
if ($LASTEXITCODE -eq 0) {
    Write-Error "Ja existe um servidor na porta $Porta. Escolha outra com -Porta, ou derrube o que esta la."
}

if (Test-Path $base) { Remove-Item $base -Recurse -Force }
New-Item -ItemType Directory $base -Force | Out-Null

Write-Host "criando cluster em $dados" -ForegroundColor Cyan
& $initdb -D $dados -U postgres --auth-local=trust --auth-host=trust -E UTF8 --locale=C | Out-Null

Write-Host "subindo na porta $Porta" -ForegroundColor Cyan

# Aqui nao se usa pg_ctl start, por dois motivos, os dois so no Windows:
#
#   1. o postgres herda os handles de saida do pg_ctl, e se essa saida
#      estiver num pipe do PowerShell o pipe so fecha quando o servidor
#      morrer, ou seja, nunca durante o script;
#   2. Start-Process -NoNewWindow -Wait espera a arvore de processos toda,
#      e o servidor e filho do pg_ctl, entao travaria do mesmo jeito.
#
# Subir o postgres.exe direto, sem esperar, e confirmar com pg_isready
# resolve os dois.
$postgres = Join-Path $PastaBin "postgres.exe"
$argsPostgres = "-D `"$dados`" -p $Porta -c listen_addresses=127.0.0.1 -c log_min_messages=warning"

Start-Process -FilePath $postgres -ArgumentList $argsPostgres `
    -NoNewWindow `
    -RedirectStandardOutput $log `
    -RedirectStandardError  (Join-Path $base "servidor.err") | Out-Null

$pronto = $false
foreach ($tentativa in 1..40) {
    & $pgisready -h 127.0.0.1 -p $Porta -q
    if ($LASTEXITCODE -eq 0) { $pronto = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $pronto) {
    Write-Error "O servidor nao respondeu na porta $Porta. Veja $log"
}

function Executar-Sql {
    param([string] $Arquivo, [string] $Comando, [switch] $ParaNoErro)
    $args = @("-h", "127.0.0.1", "-p", $Porta, "-U", "postgres", "-d", $Banco, "-q")
    if ($ParaNoErro) { $args += @("-v", "ON_ERROR_STOP=1") }
    if ($Arquivo)    { $args += @("-f", $Arquivo) }
    if ($Comando)    { $args += @("-c", $Comando) }
    & $psql @args
}

try {
    & $psql -h 127.0.0.1 -p $Porta -U postgres -d postgres -q -c "create database $Banco" | Out-Null

    Write-Host "`ninstalando o guarda" -ForegroundColor Cyan
    foreach ($etapa in @("01-base.sql", "02-guardas-dml.sql", "03-guardas-ddl.sql", "04-instalador.sql")) {
        Write-Host "  $etapa"
        Executar-Sql -Arquivo (Join-Path $raiz "postgresql\$etapa") -ParaNoErro
    }

    Write-Host "`nteste de aceitacao" -ForegroundColor Cyan
    Executar-Sql -Arquivo (Join-Path $raiz "postgresql\90-teste-aceitacao.sql")

    $dsn = "host=127.0.0.1 port=$Porta dbname=$Banco user=postgres"

    if ($Manter) {
        Write-Host "`nservidor no ar. Para usar o painel:" -ForegroundColor Green
        Write-Host "  `$env:GUARDA_DSN = `"$dsn`""
        Write-Host "  python painel\servidor.py --engine postgresql"
        Write-Host "`nPara derrubar depois:"
        Write-Host "  & `"$pgctl`" -D `"$dados`" stop"
    }
}
finally {
    if (-not $Manter) {
        Write-Host "`nderrubando o cluster" -ForegroundColor DarkGray
        Start-Process -FilePath $pgctl -ArgumentList "-D `"$dados`" -w -m fast stop" `
            -NoNewWindow -Wait `
            -RedirectStandardOutput (Join-Path $base "pg_ctl-stop.out") `
            -RedirectStandardError  (Join-Path $base "pg_ctl-stop.err")
        Start-Sleep -Milliseconds 500
        Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
