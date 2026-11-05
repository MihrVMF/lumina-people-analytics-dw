# People Analytics e Gestão de Pessoas · Grupo Lumina (2025/2026)

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white) ![Power BI](https://img.shields.io/badge/Power_BI-F2C811?style=for-the-badge&logo=powerbi&logoColor=black) ![DAX](https://img.shields.io/badge/DAX-F2C811?style=for-the-badge&logo=powerbi&logoColor=black) ![SQL](https://img.shields.io/badge/SQL-Data_Warehouse-316192?style=for-the-badge) ![Netlify](https://img.shields.io/badge/Netlify-00C7B7?style=for-the-badge&logo=netlify&logoColor=white)

Painel de People Analytics construído para o **Grupo Lumina (Telecom & Cloud)**, consolidando jornada e ponto eletrônico, turnover, absenteísmo, banco de horas, recrutamento e seleção (SLA de vagas), ocorrências disciplinares, feedbacks e avaliação de desempenho (AVD), com foco no fechamento de **out/2026** (187 colaboradores ativos em 3 empresas e 6 áreas).

Carreguei o histórico de 2025 e 2026 no PostgreSQL para garantir que o saldo acumulado de banco de horas, a vigência de cargos (SCD Tipo 2) e a comparação com ciclos anteriores de AVD tivessem lastro completo, mantendo os visuais focados na série de **jan/2026 a out/2026**. Além do projeto `.pbip`/`.pbix` no Power BI (com modelo semântico em TMDL), gerei uma versão web autônoma hospedada no Netlify para visualização imediata no navegador.

* **Dashboard Online (Netlify):** [case-rh-grupo-lumina.netlify.app](https://case-rh-grupo-lumina.netlify.app)
* **Apresentação Executiva (PDF):** [docs/Apresentacao_Executiva_Case_RH_Lumina.pdf](docs/Apresentacao_Executiva_Case_RH_Lumina.pdf)

![Visão Geral](imagens/01-visao-geral.png)

## Arquitetura e ferramentas

`Sólides (Ponto + Gestão + AVD)` → `PostgreSQL (schema solides)` → `PostgreSQL (schema solides_bi)` → `Power BI (TMDL / PBIP) e Web`

No schema `solides` entram as 18 tabelas brutas dos três módulos da Sólides (Tangerino Ponto, Sólides Gestão e Avaliação de Desempenho V3). No schema `solides_bi` ficam o modelo estrela materializado (4 dimensões e 6 fatos), a tabela de metas e as views analíticas. O Power BI consome apenas a camada `solides_bi` em modo Importar, com medidas e relacionamentos versionados em TMDL.

**Ferramentas:** PostgreSQL, SQL, Power BI Desktop (Power Query, DAX e modo desenvolvedor `.pbip`/TMDL), Node.js e Netlify.

## Fonte e tabelas utilizadas

A base reproduz a estrutura real de produção da Sólides dividida em três módulos de origem (18 tabelas brutas):

| Módulo | Tabelas de origem (`solides`) | Para que usei | Observação |
|---|---|---|---|
| **Ponto / DP (Tangerino)** | `ponto_consolidado_diario`, `ponto_saldo_diario` | Fato de ponto diário e saldo de banco de horas | 47.175 batidas diárias apuradas e 10.773 registros de saldo |
| **Ponto / DP (Cadastros)** | `funcionario`, `empresa`, `setor`, `cargo`, `lider`, `feriado`, `regra_escala`, `regra_ponto` | Vínculo trabalhista mestre, jornada prevista e regras de hora extra | 296 vínculos divididos em 3 empresas e 10 setores |
| **Sólides Gestão (Pessoas)** | `colaborador`, `colaborador_historico`, `departamento` | Dados demográficos, lotação e histórico de movimentação (SCD2) | 296 cadastros e 2.072 snapshots mensais de histórico |
| **Sólides Gestão (R&S e Clima)** | `vaga`, `ocorrencia` | Fato de recrutamento (SLA de vagas), feedbacks e medidas disciplinares | 55 vagas (124 posições) e 1.844 ocorrências registradas |
| **AVD V3 (Desempenho)** | `avaliacao_ciclo`, `avaliacao`, `avaliacao_criterio` | Ciclos semestrais de avaliação, aderência e notas por competência | 4 ciclos, 567 avaliações e 2.028 notas por critério |

## Banco de dados: schemas, tabelas e views

O banco está dividido nos schemas `solides` (camada bruta transacional) e `solides_bi` (Data Mart dimensional).

### Schema `solides` (18 tabelas transacionais de origem)

| Tabela | Colunas principais | Linhas |
|---|---|---:|
| `solides.ponto_consolidado_diario` | `id, funcionario_id, data_apuracao, horas_previstas_min, horas_trabalhadas_min, tempo_falta_min, hora_extra_50_min, hora_extra_100_min, tipo_movimentacao` | 47.175 |
| `solides.ponto_saldo_diario` | `funcionario_id, data_apuracao, saldo_horas_min, saldo_banco_horas_acumulado_min` | 10.773 |
| `solides.colaborador_historico` | `colaborador_id, data_referencia, ativo, gestor_id, departamento_id, cargo_nome, unidade_id` | 2.072 |
| `solides.avaliacao_criterio` | `avaliacao_ciclo_id, avaliador_id, avaliado_id, criterio_id, criterio_tipo, nota, peso` | 2.028 |
| `solides.ocorrencia` | `id, colaborador_id, tipo, classificacao, data_ocorrencia, valor` | 1.844 |
| `solides.avaliacao` | `avaliacao_ciclo_id, avaliador_id, avaliado_id, data_avaliacao, respondida, qtd_criterios` | 567 |
| `solides.funcionario` | `id, nome, cpf, empresa_id, setor_id, ultimo_gestor_id, data_admissao, data_demissao, cargo_id` | 296 |
| `solides.colaborador` | `id, nome, cpf, genero, etnia, escolaridade, tipo_contrato, ativo, gestor_id, departamento_id` | 296 |
| `solides.vaga` | `id, titulo, cargo, tipo, status, data_abertura, data_prazo, data_status, qtd_posicoes` | 55 |
| Auxiliares (`empresa`, `setor`, `departamento`, `cargo`, `lider`, `feriado`, `regra_escala`, `regra_ponto`, `avaliacao_ciclo`) | Cadastros de apoio de DP e Gestão | 84 |

### Schema `solides_bi` (modelo estrela consumido pelo Power BI)

| Tabela / View | Colunas principais | Linhas | Origem e regra |
|---|---|---:|---|
| `pbi_fato_ponto_diario` | `data, colaborador_key, gestor_key, previsto_min, trabalhado_min, ausencia_liquida_min, he_paga_min, saldo_banco_acum_min` | 57.948 | Conciliação de `ponto_consolidado_diario` e `ponto_saldo_diario` |
| `pbi_fato_headcount_mensal` | `mes_ref, colaborador_key, gestor_key, headcount_fim_mes, dias_ativos_mes, dias_no_mes` | 2.099 | Fotografia mensal e colaborador-equivalente (`dias_ativos / dias_no_mes`) |
| `pbi_fato_avaliacao` | `ciclo_key, avaliado_key, avaliador_key, criterio_tipo, nota, qtd_finalizada, qtd_pendente` | 2.088 | Avaliações explodidas por critério com flags no 1º critério para não duplicar contagens |
| `pbi_fato_ocorrencia` | `ocorrencia_id, data_ocorrencia, colaborador_key, gestor_key, tipo_ocorrencia_key, classificacao` | 1.844 | Feedbacks e medidas disciplinares vinculados à versão SCD2 vigente na data |
| `pbi_fato_movimentacao` | `data_evento, colaborador_key, gestor_key, tipo_evento, motivo_demissao, tempo_casa_dias` | 200 | Admissões e desligamentos (base para turnover e retenção precoce de 90 dias) |
| `pbi_fato_vaga` | `vaga_id, data_abertura, data_fechamento, status, tipo, dias_para_fechar, dentro_do_prazo` | 55 | Vagas com cálculo de SLA em dias corridos e status no prazo |
| `pbi_dim_calendario` | `data, ano, trimestre, mes, mes_ano, inicio_mes, fim_mes, dia_util, feriado` | 1.461 | Calendário de 2024 a 2027 cruzado com `solides.feriado` |
| `pbi_dim_colaborador` | `colaborador_key, colaborador_id, nome, empresa, area, cargo, gestor_id, gestor_nome, valido_de, valido_ate, atual` | 297 | Dimensão SCD Tipo 2 (296 vínculos + 1 linha sentinela `-1` para integridade referencial) |
| `pbi_meta_indicador` | `indicador, vigencia_inicio, nome, unidade, sentido, meta, limite_amarelo, limite_vermelho` | 8 | Metas oficiais com faixas semafóricas (verde, amarelo e vermelho) |
| `pbi_dim_tipo_ocorrencia` e `pbi_dim_ciclo_avaliacao` | Categorias de ocorrência (feedback / advertência / suspensão) e ciclos de AVD | 9 | Dimensões de apoio de Gestão e Cultura |

## Modelo de dados

![Modelo de dados](imagens/diagrama.png)

O modelo segue arquitetura Star Schema de Kimball com **4 dimensões**, **6 tabelas fato** e **1 tabela de metas desconectada** (consultada via DAX pelo código do indicador):

* **Chave durável (`colaborador_id`) vs Chave substituta (`colaborador_key`):** Como pessoas mudam de área, cargo ou gestor ao longo do ano, `dim_colaborador` foi construída como **SCD Tipo 2** (`valido_de`, `valido_ate`, `atual`). Cada fato liga na `colaborador_key` vigente na data exata do evento, garantindo que uma transferência em outubro não altere o histórico de horas extras ou feedbacks dos meses anteriores.
* **Role-playing dimension de Gestor (`Avaliador`):** Nas avaliações de desempenho há dois papéis distintos (quem foi avaliado e quem avaliou). No Power BI, `Avaliador` referencia a versão atual dos líderes para filtrar pendências por avaliador sem conflito de relacionamento ativo com `Colaborador`.
* **Relacionamentos inativos com `USELIATIONSHIP`:** Em `Vaga`, a relação ativa com `Calendario` é pela `data_abertura` (para vagas abertas no mês) e a relação inativa é pela `data_fechamento` (ativada via `USERELATIONSHIP` nas medidas de SLA e vagas fechadas).

## Problemas encontrados e tratamentos

* **Casamento entre sistemas sem chave única compartilhada:** O Sólides Ponto (`solides.funcionario`) e o Sólides Gestão (`solides.colaborador`) usam IDs internos diferentes. Criei a view materializada `aux_ponte_colaborador` que higieniza o CPF (`regexp_replace` mantendo 11 dígitos) e faz o casamento entre os dois sistemas, resolvendo casos de recontratação pela admissão mais próxima. Nenhuma view final expõe o CPF (conformidade com LGPD).
* **Registros de teste e feriados móveis:** O cadastro bruto continha registro de teste (`motivo_demissao = 'TESTE_SISTEMA'`) e o Carnaval de 2025 estava cadastrado na data de 2026 na tabela de feriados. Ambos foram tratados via CTE na camada `solides_bi` sem alterar o dado bruto no `solides`.
* **Absenteísmo líquido vs abono e férias:** No espelho de ponto, dias de férias (`tipo_movimentacao = 'FERIAS'`) e faltas abonadas pela chefia apareciam junto com ausências. Na `fato_ponto_diario`, separei `ausencia_bruta_min` de `ausencia_liquida_min`, descontando abonos e zerando o tempo previsto em dias de férias para não inflar o absenteísmo.
* **Fato de avaliação no grão de critério sem duplicar cabeçalho:** Como cada avaliação possui até 4 critérios (Cultura, Entrega, Autogestão e Liderança), explodir na fato multiplicaria a contagem de avaliações por 4. A solução no SQL foi gravar `qtd_avaliacao`, `qtd_finalizada` e `qtd_pendente` apenas na linha `rn = 1` de cada avaliação e `0` nas demais, permitindo usar `SUM` simples no DAX tanto para total de avaliações quanto para média de notas por critério.
* **Performance de consulta (158s para < 50ms):** Inicialmente a camada `solides_bi` usava views simples empilhadas, o que recalculava o SCD Tipo 2 a cada linha das fatos. Transformei a estrela base em `MATERIALIZED VIEW` com índices nas chaves substitutas e criei a procedure `solides_bi.atualizar()`, derrubando o tempo de resposta para milissegundos.

## Validações

Todos os indicadores de outubro/2026 e do acumulado anual foram validados comparando o retorno das queries SQL no PostgreSQL com as medidas DAX no Power BI:

| Indicador (Out/2026) | Regra de cálculo | SQL (`solides_bi`) | Power BI (DAX) | Meta / Status |
|---|---|---:|---:|---|
| **Headcount Ativo** | Ativos no fim do mês (`headcount_fim_mes = 1`) | 187 | 187 | Base ativa |
| **Headcount Médio** | `SUM(dias_ativos_mes) / dias_no_mes` | 185,5 | 185,5 | Denominador do turnover |
| **Turnover no Mês** | `8 desligamentos / 185,5 HC médio` | 4,3% (8 desl.) | 4,3% (8 desl.) | Meta ≤ 5,0% (Verde) |
| **Absenteísmo Líquido** | `706,6h ausência líq. / 33.424,0h previstas` | 2,1% | 2,1% | Meta ≤ 3,0% (Verde) |
| **Hora Extra (% Jornada)** | `2.878,0h HE / 33.424,0h previstas` | 8,6% | 8,6% | Meta ≤ 8,0% (Amarelo) |
| **Banco de Horas (Saldo Médio)** | `+823,3h líquidas / 175 colab. com ponto` | +4,7h | +4,7h | Meta ±4,0h (Amarelo) |
| **SLA Médio de Vagas** | Média de dias corridos das vagas fechadas no mês | 26 dias | 26 dias | Meta ≤ 25 dias (Amarelo) |
| **Cobertura de Feedback** | `164 colab. com feedback / 186 elegíveis` | 88,2% | 88,1% | Meta ≥ 95,0% (Amarelo) |
| **Medidas Disciplinares** | Advertências + suspensões aplicadas no mês | 13 | 13 | Meta ≤ 50 (Verde) |
| **Conclusão de AVD (2026.2)** | `170 finalizadas / 178 atribuídas no ciclo` | 95,5% | 95,5% | Meta 100% (Amarelo) |

## O que os dados mostram

* **Quadro geral estável, mas com sobrecarga concentrada em uma única área:** No consolidado do Grupo Lumina, o turnover (4,3% e 8 desligamentos) e o absenteísmo líquido (2,1%) fecharam outubro dentro da meta. Porém, o algoritmo do **Painel de Atenção** revela que 4 dos 5 alertas amarelos da companhia vêm de **Operações de Campo**.
* **Gargalo operacional em Operações de Campo:** A área responde por sozinha pela pressão de jornada da empresa, atingindo **8,6% de horas extras** no consolidado (com pico entre abril e maio acima de 14% durante expansão de rede) e saldo médio de **+4,7h por colaborador** no banco de horas (+1.263h positivas acumuladas contra -440h negativas).
* **Passivo trabalhista em banco de horas:** Há **18 técnicos** acima do limite prudencial de +40h acumuladas no banco, exigindo escala de compensação nos 15 dias seguintes para evitar vencimento de banco e pagamento obrigatório de HE a 100%.
* **Recrutamento próximo da meta, pressionado por vagas técnicas:** O SLA médio caiu 1 dia em relação a setembro e fechou em **26 dias** (meta de 25 dias). Enquanto vagas de Atendimento e Administrativo fecham em menos de 20 dias, posições seniores de Engenharia e Cloud puxam a média para cima.
* **Liderança e Cultura:** O ciclo de Avaliação de Desempenho 2026.2 atingiu **95,5% de conclusão** (+6,5 p.p. sobre o ciclo 2026.1, restando 8 avaliações pendentes). A cobertura de feedbacks chegou a **88,1%** (195 feedbacks registrados no mês), também com a maior lacuna nas equipes de campo em razão da rotina externa.

## Medidas DAX principais

As medidas do modelo ficam centralizadas na tabela `_Medidas.tmdl` (mais de 110 medidas organizadas por pastas de exibição):

| Medida | Expressão DAX resumida | Objetivo |
|---|---|---|
| `[Turnover %]` | `DIVIDE([Desligamentos], [HC Medio], BLANK()) * 100` | Taxa mensal de rotatividade ponderada pelo headcount médio diário |
| `[Absenteismo %]` | `DIVIDE(SUM('Ponto Diario'[ausencia_liquida_min]), SUM('Ponto Diario'[previsto_min]), BLANK()) * 100` | Percentual de tempo perdido por faltas e atrasos não abonados |
| `[Hora Extra %]` | `DIVIDE(SUM('Ponto Diario'[he_paga_min]), SUM('Ponto Diario'[previsto_min]), BLANK()) * 100` | Peso das horas extras (50% + 100%) sobre a jornada contratual prevista |
| `[Banco Saldo Medio h]` | `DIVIDE([Banco Saldo Liquido min], [Banco Colab com Saldo], BLANK()) / 60` | Saldo acumulado médio em horas no último dia com apuração no mês |
| `[Vagas SLA Medio Dias]` | `CALCULATE(AVERAGE(Vaga[dias_para_fechar]), Vaga[fechada] = 1, USERELATIONSHIP(Vaga[data_fechamento], Calendario[data]))` | Tempo médio de fechamento ativando a relação inativa pela data de encerramento |
| `[Feedback Cobertura %]` | `DIVIDE([Feedback Cobertos], [HC Elegivel Feedback], BLANK()) * 100` | Percentual da equipe ativa que recebeu ao menos 1 feedback no mês |
| `[AVD Concluidas %]` | `DIVIDE([AVD Finalizadas], [AVD Total], BLANK()) * 100` | Taxa de conclusão do ciclo de avaliação vigente no período selecionado |

## Páginas do dashboard

### 01 · Visão Geral e Painel de Atenção
![Visão Geral](imagens/01-visao-geral.png)

### 02 · Performance e Jornada (Turnover, Absenteísmo, HE e Banco de Horas)
![Performance e Jornada](imagens/02-performance-e-jornada.png)

### 03 · Recrutamento e Seleção (Funil de Vagas e SLA)
![Recrutamento e Seleção](imagens/03-recrutamento-e-selecao.png)

### 04 · Gestão e Cultura (Feedbacks, Medidas Disciplinares e AVD)
![Gestão e Cultura](imagens/04-gestao-e-cultura.png)

### 05 · Detalhamento Nominal por Colaborador
![Detalhamento Individual](imagens/05-detalhamento-individual.png)

## Arquivos do projeto

| Arquivo / Pasta | Conteúdo |
|---|---|
| `sql/01_schema_solides.sql` | Criação das 18 tabelas brutas do schema `solides` (Ponto, Gestão e AVD V3) |
| `sql/02_seed_solides_ficticio.sql` | Carga completa de dados realistas (296 vínculos, 47.175 batidas de ponto, vagas, ocorrências e avaliações) |
| `sql/03_solides_bi_views.sql` | Criação do schema `solides_bi`, views materializadas do modelo estrela, views de visuais e procedure `solides_bi.atualizar()` |
| `dados_pbi/*.csv` | As 11 tabelas/views da camada `solides_bi` exportadas em CSV UTF-8 para carga rápida |
| `powerbi/Lumina RH Case.pbix` | Relatório Power BI completo em arquivo único (`.pbix`) |
| `powerbi/Lumina.pbip` | Projeto em formato Power BI Developer Mode apontando para `GCE.SemanticModel` (TMDL) e `GCE.Report` (PBIR) |
| `dashboard/Relatorio_Case_RH_Lumina.html` | Versão web interativa 100% standalone (motor analítico e dados embarcados em arquivo único) |
| `docs/Apresentacao_Executiva_Case_RH_Lumina.pdf` | Apresentação executiva em 6 lâminas com diagnóstico e plano de ação por módulo |

## Como reproduzir do zero

1. **Banco PostgreSQL:** Crie um banco no PostgreSQL e rode na ordem: `sql/01_schema_solides.sql`, `sql/02_seed_solides_ficticio.sql` e `sql/03_solides_bi_views.sql`.
2. **Power BI Desktop:** Abra diretamente o arquivo `powerbi/Lumina RH Case.pbix` (os dados já estão importados no modelo) ou abra `powerbi/Lumina.pbip` para inspecionar as pastas `.tmdl` e `.pbir`. Caso queira recarregar via CSV local, aponte a pasta `dados_pbi/` para `C:\lumina\dados_pbi\` em *Transformar dados > Configurações da fonte de dados*.
3. **Navegador (sem instalar nada):** Abra `dashboard/Relatorio_Case_RH_Lumina.html` em qualquer navegador ou acesse [case-rh-grupo-lumina.netlify.app](https://case-rh-grupo-lumina.netlify.app).
