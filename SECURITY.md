# Segurança

## Reportando uma falha

Falha de segurança não vai em issue pública. Mande por e-mail para o
responsável pelo repositório, com o que for possível dos itens abaixo:

- qual banco e qual versão
- o que dá para fazer que não deveria ser possível
- passos para reproduzir
- se já existe alguém explorando isso

Resposta em até 5 dias úteis.

## Modelo de ameaça

É importante ser honesto sobre o que este sistema faz e o que ele não faz,
porque prometer demais é pior que não ter proteção nenhuma: o time relaxa
achando que está coberto.

### Contra o que ele protege

Erro humano de quem tem acesso legítimo de escrita ao banco. `DELETE` sem
`WHERE`, `WHERE` que pega mais linhas do que a pessoa imaginava, `OR` no
lugar de `AND`, cascata inesperada, `TRUNCATE` distraído, `DROP TABLE` na
conexão errada. É esse o alvo, e para esse alvo ele funciona.

### Contra o que ele NÃO protege

**Não protege contra quem tem superusuário e quer mesmo apagar.** Quem é
superusuário no PostgreSQL pode chamar `guarda.manutencao()` e remover a
proteção, ou usar `session_replication_role = replica`, que desliga toda
trigger de usuário. No SQL Server, quem tem `CONTROL SERVER` desativa
qualquer trigger. No MySQL, quem tem `SUPER` reconfigura o servidor.

Isso não é falha de implementação, é consequência de como bancos
funcionam. Superusuário manda. O que dá para fazer, e está feito, é
registrar tudo em `guarda.evento` e devolver a proteção pelo watchdog.

Se a sua preocupação é ação maliciosa de quem tem acesso administrativo, o
controle certo não é este projeto: é reduzir quem tem superusuário,
auditoria externa ao banco e backup em local que o operador do banco não
alcança.

**Não substitui backup.** Nenhuma trigger recupera dado já apagado e
commitado. Backup com PITR testado continua sendo a última linha, e é a
única que funciona quando todas as outras falharem.

**Não protege o que não tem trigger.** Tabela criada depois da instalação
só está coberta se o banco adotar sozinho (PostgreSQL e SQL Server) ou se
o watchdog tiver passado (MySQL). Monitore o `rearmar.py`, e trate ausência
de execução como incidente. Ver [docs/operacao.md](docs/operacao.md).

Lista completa e detalhada em [docs/limitacoes.md](docs/limitacoes.md).

## Superfície de ataque do próprio guard

O guard é código que roda dentro do banco, então vale olhar para ele com
desconfiança:

**Funções `SECURITY DEFINER`.** As funções do PostgreSQL rodam com o
privilégio de quem as criou. Todas têm `search_path` fixo em
`pg_catalog, guarda`, que é a defesa contra alguém criar uma função com
nome colidente num esquema à frente no caminho de busca e sequestrar a
chamada.

**Entrada que vira SQL.** O instalador monta `CREATE TRIGGER` com nome de
esquema e tabela. Esses nomes vêm do catálogo do banco, não do usuário, e
passam por `quote_ident`. O painel nunca concatena entrada em SQL: tudo vai
por parâmetro.

**O painel não tem autenticação.** É proposital, e por isso ele escuta em
`127.0.0.1`. Ele liga e desliga proteção de banco, então não é coisa para
ficar aberta na rede. Para acesso remoto, use túnel SSH. Para deixar o time
olhar sem risco, use `--somente-leitura`. Quem consegue falar com o painel
consegue desligar a proteção, com justificativa registrada.

**Credencial do watchdog.** O `rearmar.py` precisa de privilégio para criar
trigger. Use um usuário só dele, não o mesmo da aplicação, e guarde a senha
fora do repositório. Ver `.env.example`.

## Dado pessoal e LGPD

`guarda.evento` guarda quem executou, de qual máquina, com qual aplicação e
qual justificativa. Isso é dado pessoal de colaborador, com base legal de
legítimo interesse (segurança da informação).

Duas coisas importantes:

- **Defina retenção.** A tabela cresce para sempre se ninguém expurgar.
  Sugestão de 12 meses, com o expurgo passando pelo próprio
  `guarda.liberar()`, para o expurgo da auditoria também ficar auditado.
- **A justificativa é texto livre.** Oriente o time a colocar número de
  chamado, e não dado de cliente. "expurgo do CPF 123.456.789-00" põe dado
  pessoal de titular numa tabela de log.

O rastro de exclusão de dado pessoal atende ao art. 37 da LGPD, que exige
registro das operações de tratamento.
