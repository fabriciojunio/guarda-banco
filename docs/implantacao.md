# Implantando na empresa

Guia para levar isso de "projeto no meu GitHub" para "rodando em produção
com o time inteiro dependendo".

A ordem importa. O maior risco de um projeto assim não é técnico, é
político: se a primeira experiência do time for um bloqueio inesperado no
meio de uma correção urgente, o guard vira "aquela coisa que atrapalha" e
alguém vai desinstalar na primeira oportunidade.

Por isso o plano começa em modo observação, e só depois passa a bloquear.

---

## Fase 0, antes de falar com qualquer pessoa

**Levante o tamanho do problema.** Argumento sem número não convence
gestor. Procure no histórico da empresa:

- quantos incidentes de dado apagado por engano aconteceram nos últimos 2 anos
- quanto tempo cada um levou para ser percebido, e para ser corrigido
- quantas pessoas ficaram paradas durante o restore

Se não houver histórico registrado, pergunte aos mais antigos. Sempre tem
história. É essa história que abre a porta.

**Descubra quem manda no banco.** Se existe DBA ou time de infraestrutura,
eles precisam ser aliados desde o primeiro dia, não descobrir depois que
alguém mexeu nas triggers. Se você implantar sem eles e der problema, a
conversa fica impossível.

---

## Fase 1, prova em homologação (1 semana)

Sem pedir permissão para nada, porque não toca em produção.

```bash
git clone https://github.com/fabriciojunio/guarda-banco.git
cd guarda-banco

# validação isolada, sobe um banco descartável e derruba no fim
./ferramentas/postgres-local.ps1
```

Depois, no banco de homologação da empresa:

```bash
psql -f postgresql/01-base.sql
psql -f postgresql/02-guardas-dml.sql
psql -f postgresql/03-guardas-ddl.sql
psql -f postgresql/04-instalador.sql
psql -f postgresql/90-teste-aceitacao.sql   # 17 casos, todos têm que passar
```

Ajuste o ambiente para não mentir na auditoria:

```sql
UPDATE guarda.config SET valor = 'homologacao' WHERE chave = 'ambiente';
```

**No fim desta fase você tem:** a saída do teste de aceitação rodando no
banco da empresa. É isso que você leva para a reunião, não slide.

---

## Fase 2, conversa com o gestor (30 minutos)

Leve três coisas:

1. **O incidente que já aconteceu aqui.** Nome, data, quanto tempo parou.
2. **A saída do teste de aceitação** rodando no banco de homologação de vocês.
3. **O plano de rollout abaixo**, deixando claro que começa sem bloquear nada.

Perguntas que vão aparecer, e as respostas honestas:

> **"Isso vai travar o time?"**
> Nas primeiras semanas, não: entra em modo observação, só registrando. Aí a
> gente olha o que teria sido bloqueado e calibra o limite antes de ligar.

> **"E se precisar apagar muita coisa de propósito?"**
> Continua podendo. Abre transação, chama `guarda.liberar('motivo')`, roda o
> comando, confere o número de linhas e dá COMMIT. Leva 10 segundos a mais e
> exige olhar o resultado antes de confirmar, que é justamente o ponto.

> **"Quem mantém isso?"**
> É SQL padrão do próprio banco, sem serviço externo, sem agente, sem
> dependência de fornecedor. Desinstala com um script se um dia atrapalhar.

> **"E o desempenho?"**
> A contagem é por linha afetada, então pesa em operação grande, que é
> justamente o que se quer desestimular. Operação pequena, que é 99% do dia,
> não sente. Meça em homologação antes de prometer número.

> **"Quanto custa?"**
> Nada de licença. O custo é o tempo de implantação e a calibragem inicial.

---

## Fase 3, produção em modo observação (2 a 4 semanas)

Instala tudo, mas com limite alto o suficiente para não bloquear ninguém:

```sql
UPDATE guarda.config SET valor = 'producao'  WHERE chave = 'ambiente';
UPDATE guarda.config SET valor = '1000000'   WHERE chave = 'limite_delete_padrao';
UPDATE guarda.config SET valor = '1000000'   WHERE chave = 'limite_update_padrao';
UPDATE guarda.config SET valor = '100'       WHERE chave = 'registrar_acima_de';
```

Com isso nada é bloqueado, mas toda operação acima de 100 linhas vai para
`guarda.evento`. É a fase mais importante do projeto inteiro, e a que
quase todo mundo pula.

**Comunique antes de instalar.** Uma mensagem curta no canal do time:

> Instalei no banco de produção um registro de operações grandes. **Nada
> está sendo bloqueado.** Nas próximas semanas vou olhar o que costuma
> acontecer para calibrar. Se alguém receber erro estranho vindo de algo
> chamado GUARDA, me chama que eu desligo na hora.

Depois de duas semanas, olhe a realidade:

```sql
SELECT tabela,
       count(*)              AS operacoes,
       max(linhas)           AS maior,
       percentile_disc(0.95) WITHIN GROUP (ORDER BY linhas) AS p95
  FROM guarda.evento
 WHERE ocorrido_em > now() - interval '14 days'
   AND resultado = 'permitido'
 GROUP BY tabela
 ORDER BY maior DESC;
```

O limite de cada tabela sai daí: **p95 com folga**. Tabela de log com
expurgo diário de 50 mil linhas precisa de limite alto ou de estar
desativada de propósito. Tabela de cadastro onde ninguém nunca mexe em mais
de 20 linhas pode ter limite de 100.

---

## Fase 4, ligando a proteção (1 dia)

Aplique os limites calibrados, tabela por tabela, começando pelas que mais
doem se forem apagadas:

```sql
INSERT INTO guarda.politica (esquema, tabela, limite_delete, limite_update, observacao)
VALUES ('public', 'cliente', 500, 500, 'calibrado com p95 de 14 dias, OS-1234')
ON CONFLICT (esquema, tabela) DO UPDATE
   SET limite_delete = excluded.limite_delete,
       limite_update = excluded.limite_update;
```

Agende o watchdog **antes** de ligar, não depois. Ver
[operacao.md](operacao.md).

Comunique de novo, agora com o runbook:

> A partir de hoje operação acima do limite é bloqueada. Se você precisa
> mesmo apagar muita coisa, o caminho é este: [link do runbook]. Leva 10
> segundos. Se travar algo urgente, me chama.

---

## Fase 5, rotina (para sempre)

| Quando | O quê |
|--------|-------|
| A cada 5 min | Watchdog roda. Saída 2 é alerta. Ausência de execução também. |
| Semanal | Olhar `guarda.evento` com `resultado = 'bloqueado'`. Cada bloqueio é um acidente que não aconteceu, e é isso que se leva para a reunião. |
| Semanal | Olhar tabela desativada de propósito. Carga que terminou e ninguém religou é buraco aberto. |
| Mensal | Recalibrar limite de tabela que cresceu. |
| A cada upgrade do banco | Rodar o teste de aceitação de novo. |

Consulta para a reunião mensal:

```sql
SELECT date_trunc('week', ocorrido_em) AS semana,
       count(*) FILTER (WHERE resultado = 'bloqueado') AS acidentes_evitados,
       count(*) FILTER (WHERE resultado = 'liberado')  AS operacoes_conscientes
  FROM guarda.evento
 WHERE ocorrido_em > now() - interval '90 days'
 GROUP BY 1 ORDER BY 1;
```

---

## Se der errado

Sinais de que a implantação está azedando, e o que fazer:

**Muita gente pedindo liberação toda hora.** O limite está apertado demais
para aquela tabela. Suba, não discuta. Guard que atrapalha o trabalho é
guard que vai ser desinstalado.

**Alguém desligou a proteção e não religou.** Esperado, e é por isso que a
revisão semanal existe. Se acontecer sempre na mesma tabela, ela
provavelmente precisa de limite maior, e não de ficar desligada.

**Bloqueio no meio de incidente crítico.** Sério, e a resposta é
`guarda.liberar()`, não desinstalar. Se aconteceu, revise se aquela tabela
devia estar protegida com aquele limite.

**Desinstalação.** Se precisar sair, sai limpo e sem deixar resíduo:

```sql
\i postgresql/99-desinstalar.sql
```

Melhor sair inteiro do que ficar meio instalado, porque proteção parcial em
que o time confia é pior que proteção nenhuma.
