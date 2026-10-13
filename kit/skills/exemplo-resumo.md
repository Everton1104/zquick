---
name: exemplo-resumo
description: Exemplo de skill — resumir um arquivo markdown em bullets
---
Quando pedirem para resumir um arquivo .md (menção com @ ou caminho na mensagem):

1. Leia o arquivo inteiro com file_read.
2. Devolva no máximo 5 bullets, um por seção principal do documento.
3. Comece cada bullet com o título original da seção em negrito.
4. Termine com uma linha "—" e o total de palavras do arquivo.

Isto é um EXEMPLO de skill — edite ou apague este arquivo em
ZQuick\skills e crie os seus (o nome e a descrição do cabeçalho
aparecem para o assistente, que carrega o resto com skill_read).
