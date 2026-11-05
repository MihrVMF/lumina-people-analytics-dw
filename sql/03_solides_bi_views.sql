-- =====================================================================================
-- 03_solides_bi_views.sql (Estrela Kimball materializada + Views analíticas)
-- Camada analítica do Dashboard GCE (Gestão de Pessoas - Grupo Lumina Telecom & Cloud).
--   1) Estrela Kimball (4 dimensões + 6 fatos): base reutilizável e auditável para Power BI e Web.
--   2) Views de visual (vw_): uma por bloco analítico, com COMPONENTES ADITIVOS (numerador e
--      denominador) no grão mês x empresa x área x gestor, ou no grão fino quando a medida não é
--      aditiva (vaga, colaborador x mês, avaliação).
--   3) solides_bi.meta_indicador: tabela de metas corporativas com vigência temporal.
-- Banco: lumina_dw | Schema de saída: solides_bi | Fonte: schema solides (camada bruta)
--
-- Objetos, na ordem de criação:
--   APOIO      aux_ponte_colaborador (id da Gestão -> vínculo do Ponto, por CPF; não expõe CPF)
--   DIMENSÕES  dim_calendario, dim_colaborador (SCD2), dim_ciclo_avaliacao, dim_tipo_ocorrencia
--   FATOS      fato_ponto_diario, fato_headcount_mensal, fato_movimentacao, fato_vaga,
--              fato_ocorrencia, fato_avaliacao
--   TABELA     meta_indicador (8 indicadores corporativos com metas e faixas de alerta)
--   VISUAIS    vw_turnover, vw_ponto, vw_banco_horas, vw_vaga, vw_ocorrencia_colaborador_mes,
--              vw_avd, vw_indicador_mensal, vw_meta_mensal, vw_atualizacao
--
-- Convenções:
--   * colaborador_id  = chave DURÁVEL da pessoa/vínculo:
--         > 0 = vínculo do Sólides Ponto (solides.funcionario.id), que é o mestre
--         < 0 = -(id no Sólides Gestão) para quem só existe na Gestão
--         -1  = "Não identificado"
--   * colaborador_key = chave SUBSTITUTA da versão (SCD2), estável entre recargas:
--         sinal(colaborador_id) * (|colaborador_id| * 100000 + dias entre 01/01/1900 e valido_de)
--         A 1ª versão de cada pessoa tem valido_de = 01/01/1900, logo colaborador_key = colaborador_id * 100000.
--   * gestor_key nas fatos = colaborador_key do GESTOR (role-playing de dim_colaborador), na versão
--     vigente na data do evento. -1 = sem gestor.
--   * Minutos em *_min (inteiro).
--   * Nenhuma view expõe CPF (LGPD). O CPF só é usado dentro de CTEs para casar Ponto x Gestão.
-- Autoria: André Pires
-- =====================================================================================

CREATE SCHEMA IF NOT EXISTS solides_bi;

-- v2.2 (26/10/2026): a estrela (apoio, dimensões e fatos) virou VIEW MATERIALIZADA, porque as views
-- simples empilhadas levavam até 158 s (a dim_colaborador era recalculada a cada linha das fatos).
-- As vw_ continuam views simples, lendo das materializadas. Atualizar depois de cada carga:
--     SELECT solides_bi.atualizar();
-- Reexecução: remove views e views materializadas do schema (NÃO remove a tabela meta_indicador,
-- então as metas preenchidas pelo RH são preservadas).
DO $limpa$
DECLARE r record;
BEGIN
    FOR r IN SELECT c.relname, c.relkind FROM pg_class c
             WHERE c.relnamespace = 'solides_bi'::regnamespace AND c.relkind IN ('v', 'm')
    LOOP
        IF r.relkind = 'v' THEN
            EXECUTE format('DROP VIEW IF EXISTS solides_bi.%I CASCADE', r.relname);
        ELSE
            EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS solides_bi.%I CASCADE', r.relname);
        END IF;
    END LOOP;
END
$limpa$;

-- Se a v1 chegou a ser criada, remova antes (descomente):
-- DROP VIEW IF EXISTS solides_bi.fato_avaliacao_criterio, solides_bi.fato_avaliacao, solides_bi.fato_ocorrencia,
--   solides_bi.fato_banco_horas_mensal, solides_bi.fato_ponto_diario, solides_bi.fato_desligamento,
--   solides_bi.fato_headcount_mensal, solides_bi.fato_vaga, solides_bi.dim_meta_indicador, solides_bi.dim_tipo_vaga,
--   solides_bi.dim_gestor, solides_bi.dim_colaborador, solides_bi.dim_setor, solides_bi.dim_area,
--   solides_bi.dim_empresa, solides_bi.dim_tipo_ocorrencia, solides_bi.dim_ciclo_avaliacao, solides_bi.dim_calendario,
--   solides_bi.aux_setor_area, solides_bi.aux_xref_colaborador, solides_bi.aux_vinculo, solides_bi.aux_feriado,
--   solides_bi.aux_parametro CASCADE;
-- DROP FUNCTION IF EXISTS solides_bi.fn_cpf(text), solides_bi.fn_norm_nome(text);


-- =====================================================================================
-- APOIO (não importar no Power BI)
-- =====================================================================================

-- aux_ponte_colaborador: 1 linha por (cadastro da Gestão x vínculo do Ponto com o mesmo CPF).
-- Sem casamento por CPF: 1 linha com colaborador_id = -(id da Gestão).
-- Um cadastro da Gestão casa com 2 vínculos quando há recontratação (2 casos hoje): as fatos
-- escolhem o vínculo vigente na data do evento.
CREATE MATERIALIZED VIEW solides_bi.aux_ponte_colaborador AS
WITH vinculo AS (
    SELECT f.id AS funcionario_id,
           lpad(NULLIF(regexp_replace(COALESCE(f.cpf, ''), '\D', '', 'g'), ''), 11, '0') AS cpf,
           f.data_admissao,
           f.data_demissao
    FROM solides.funcionario f
    WHERE COALESCE(f.motivo_demissao, '') <> 'TESTE_SISTEMA'      -- registro de teste do sistema
),
gestao AS (
    SELECT c.id AS gestao_id,
           lpad(NULLIF(regexp_replace(COALESCE(c.cpf, ''), '\D', '', 'g'), ''), 11, '0') AS cpf,
           c.data_admissao AS data_admissao_gestao,
           c.ativo
    FROM solides.colaborador c
)
SELECT
    g.gestao_id,
    COALESCE(v.funcionario_id::bigint, -g.gestao_id::bigint) AS colaborador_id,
    v.funcionario_id,
    v.data_admissao,
    v.data_demissao,
    -- qual cadastro da Gestão representa o vínculo (se 2 cadastros tiverem o mesmo CPF):
    -- admissão mais próxima, depois o ativo, depois o maior id
    ROW_NUMBER() OVER (PARTITION BY v.funcionario_id
                       ORDER BY abs(COALESCE(g.data_admissao_gestao, v.data_admissao) - v.data_admissao),
                                g.ativo DESC, g.gestao_id DESC) AS ordem_gestao_no_vinculo,
    -- qual vínculo representa o cadastro quando ele é GESTOR: o ativo, depois a admissão mais recente
    ROW_NUMBER() OVER (PARTITION BY g.gestao_id
                       ORDER BY (v.data_demissao IS NULL) DESC, v.data_admissao DESC NULLS LAST) AS ordem_vinculo_no_cadastro
FROM gestao g
LEFT JOIN vinculo v ON v.cpf = g.cpf;


-- =====================================================================================
-- DIMENSÕES
-- =====================================================================================

-- dim_calendario: 1 linha por dia, de 01/01/2024 até 31/12 do ano seguinte ao atual.
-- Feriado: solides.feriado com a data correta (corrigida pelo Otto em 24/10/2026). Se uma nova carga
-- do processo do Marcos voltar a gravar 1 dia antes, o Natal aparece em 24/12: conferir.
CREATE MATERIALIZED VIEW solides_bi.dim_calendario AS
WITH feriado AS (
    SELECT f.data_feriado AS data, MIN(f.descricao) AS descricao
    FROM solides.feriado f
    GROUP BY 1
),
dia AS (
    SELECT d::date AS data
    FROM generate_series(DATE '2024-01-01',
                         (date_trunc('year', DATE '2026-10-31') + interval '2 year - 1 day')::date,
                         interval '1 day') AS d
)
SELECT
    d.data,
    EXTRACT(YEAR FROM d.data)::int                             AS ano,
    EXTRACT(MONTH FROM d.data)::int                            AS mes,
    date_trunc('month', d.data)::date                          AS mes_ref,          -- 1º dia do mês
    to_char(d.data, 'YYYY-MM')                                 AS ano_mes,
    (ARRAY['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto',
           'Setembro','Outubro','Novembro','Dezembro'])[EXTRACT(MONTH FROM d.data)::int] AS mes_nome,
    (ARRAY['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'])[EXTRACT(MONTH FROM d.data)::int]
        || '/' || to_char(d.data, 'YY')                        AS mes_ano_abrev,
    EXTRACT(QUARTER FROM d.data)::int                          AS trimestre,
    EXTRACT(YEAR FROM d.data)::int || '-T' || EXTRACT(QUARTER FROM d.data)::int AS ano_trimestre,
    EXTRACT(ISODOW FROM d.data)::int                           AS dia_semana_iso,   -- 1 = segunda, 7 = domingo
    (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[EXTRACT(ISODOW FROM d.data)::int] AS dia_semana_nome,
    (EXTRACT(ISODOW FROM d.data) IN (6, 7))                    AS fim_de_semana,
    (f.data IS NOT NULL)                                       AS feriado,
    f.descricao                                                AS feriado_nome,
    (EXTRACT(ISODOW FROM d.data) < 6 AND f.data IS NULL)       AS dia_util,
    (date_trunc('month', d.data) = date_trunc('month', DATE '2026-10-31')) AS mes_atual,
    (d.data <= DATE '2026-10-31')                                   AS ate_hoje
FROM dia d
LEFT JOIN feriado f ON f.data = d.data;


-- dim_colaborador: SCD tipo 2. 1 linha por colaborador_id (vínculo do Ponto, ou pessoa só da Gestão)
-- por versão de atributos (área, gestor, cargo).
--
-- Origem das versões: solides.colaborador_historico (foto diária da Gestão). Dias consecutivos com o
-- mesmo (departamento_id, gestor_id, cargo_nome) formam uma versão.
--   valido_de / valido_ate: intervalo fechado. atual = (valido_ate = 31/12/9999).
--   Período ANTERIOR à 1ª foto: a 1ª versão é estendida até 01/01/1900, ou seja, vale o atributo
--   que estava em vigor no início da foto (o "atual" daquele momento). Sem nenhuma foto, vale o
--   cadastro atual (solides.colaborador). Quem só existe no Ponto tem 1 versão só.
-- Atributos de tipo 1 (iguais em todas as versões): nome, empresa, setor, situação, datas, motivo.
--   Setor e empresa vêm do Ponto, que não guarda histórico.
-- Área: departamento da Gestão (padrão). Sem departamento: departamento mais comum do setor do Ponto
--   entre os colaboradores casados (area_fonte = 'SETOR'). Sem nada: 'Sem área'.
-- Gestor: superior da Gestão (na versão), convertido para o id durável do gestor. Sem superior na
--   Gestão: último gestor do Ponto (funcionario.ultimo_gestor_id -> lider.id -> lider.funcionario_id).
-- Linha -1 "Não identificado": recebe ocorrências e AVDs de quem não casa com nenhum cadastro.
CREATE MATERIALIZED VIEW solides_bi.dim_colaborador AS
WITH
vinculo AS (
    SELECT f.*
    FROM solides.funcionario f
    WHERE COALESCE(f.motivo_demissao, '') <> 'TESTE_SISTEMA'
),
-- id durável: vínculo do Ponto (com o cadastro da Gestão correspondente) ou pessoa só da Gestão
pessoa AS (
    SELECT v.id::bigint AS colaborador_id, v.id AS funcionario_id, p.gestao_id
    FROM vinculo v
    LEFT JOIN solides_bi.aux_ponte_colaborador p
           ON p.funcionario_id = v.id AND p.ordem_gestao_no_vinculo = 1
    UNION ALL
    SELECT p.colaborador_id, NULL::int, p.gestao_id
    FROM solides_bi.aux_ponte_colaborador p
    WHERE p.funcionario_id IS NULL
),
-- gestor: id da Gestão -> id durável do gestor
gestor_duravel AS (
    SELECT p.gestao_id, p.colaborador_id
    FROM solides_bi.aux_ponte_colaborador p
    WHERE p.ordem_vinculo_no_cadastro = 1
),
-- foto diária: marca o início de cada versão (mudança de área, gestor ou cargo)
foto AS (
    SELECT h.colaborador_id AS gestao_id,
           h.data_referencia,
           h.departamento_id,
           h.gestor_id,
           NULLIF(trim(h.cargo_nome), '') AS cargo_nome,
           CASE WHEN LAG(h.data_referencia) OVER w IS NOT NULL
                 AND ROW(h.departamento_id, h.gestor_id, NULLIF(trim(h.cargo_nome), ''))
                     IS NOT DISTINCT FROM
                     ROW(LAG(h.departamento_id) OVER w, LAG(h.gestor_id) OVER w, LAG(NULLIF(trim(h.cargo_nome), '')) OVER w)
                THEN 0 ELSE 1 END AS inicia_versao
    FROM solides.colaborador_historico h
    WINDOW w AS (PARTITION BY h.colaborador_id ORDER BY h.data_referencia)
),
foto_ilha AS (
    SELECT f.*,
           SUM(f.inicia_versao) OVER (PARTITION BY f.gestao_id ORDER BY f.data_referencia) AS n_versao
    FROM foto f
),
versao_foto AS (
    SELECT gestao_id, n_versao, MIN(data_referencia) AS inicio,
           departamento_id, gestor_id, cargo_nome
    FROM foto_ilha
    GROUP BY gestao_id, n_versao, departamento_id, gestor_id, cargo_nome
),
versao_gestao AS (
    SELECT vf.gestao_id, vf.departamento_id, vf.gestor_id, vf.cargo_nome,
           CASE WHEN vf.n_versao = 1 THEN DATE '1900-01-01' ELSE vf.inicio END AS valido_de,   -- antes da 1ª foto
           COALESCE((LEAD(vf.inicio) OVER (PARTITION BY vf.gestao_id ORDER BY vf.inicio) - 1),
                    DATE '9999-12-31') AS valido_ate,
           'FOTO DIARIA'::text AS fonte_versao
    FROM versao_foto vf
    UNION ALL
    SELECT c.id, c.departamento_id, c.gestor_id, NULLIF(trim(c.cargo_nome), ''),
           DATE '1900-01-01', DATE '9999-12-31', 'CADASTRO ATUAL'::text
    FROM solides.colaborador c
    WHERE NOT EXISTS (SELECT 1 FROM solides.colaborador_historico h WHERE h.colaborador_id = c.id)
),
-- fallback de área: departamento mais comum (cadastro atual) entre os colaboradores de cada setor
setor_area AS (
    SELECT DISTINCT ON (v.setor_id) v.setor_id, c.departamento_id
    FROM vinculo v
    JOIN solides_bi.aux_ponte_colaborador p ON p.funcionario_id = v.id AND p.ordem_gestao_no_vinculo = 1
    JOIN solides.colaborador c ON c.id = p.gestao_id
    WHERE v.setor_id IS NOT NULL AND c.departamento_id IS NOT NULL
    GROUP BY v.setor_id, c.departamento_id
    ORDER BY v.setor_id, COUNT(*) DESC, c.departamento_id
),
nome_pessoa AS (
    SELECT p.colaborador_id, COALESCE(v.nome, c.nome) AS nome
    FROM pessoa p
    LEFT JOIN vinculo v ON v.id = p.funcionario_id
    LEFT JOIN solides.colaborador c ON c.id = p.gestao_id
),
base AS (
    SELECT
        p.colaborador_id,
        p.funcionario_id,
        p.gestao_id,
        COALESCE(vg.valido_de,  DATE '1900-01-01')          AS valido_de,
        COALESCE(vg.valido_ate, DATE '9999-12-31')          AS valido_ate,
        COALESCE(vg.fonte_versao, 'SO PONTO')               AS fonte_versao,
        CASE WHEN p.funcionario_id IS NOT NULL AND p.gestao_id IS NOT NULL THEN 'PONTO+GESTAO'
             WHEN p.funcionario_id IS NOT NULL THEN 'PONTO' ELSE 'GESTAO' END AS origem,
        COALESCE(v.nome, c.nome)                            AS nome,
        -- empresa: funcionario.empresa_id (não o empresa_id do ponto, que é o empregador no Tangerino).
        -- Só Gestão: unidade = nome fantasia.
        COALESCE(e.nome_fantasia, eu.nome_fantasia, 'Não identificada') AS empresa,
        -- área (departamento da Gestão na versão > departamento mais comum do setor > sem área)
        COALESCE(dv.nome, dsa.nome, 'Sem área')             AS area,
        CASE WHEN dv.nome  IS NOT NULL THEN 'GESTAO'
             WHEN dsa.nome IS NOT NULL THEN 'SETOR'
             ELSE 'SEM AREA' END                            AS area_fonte,
        COALESCE(s.nome, 'Sem setor')                       AS setor,
        COALESCE(vg.cargo_nome, cg.nome, 'Sem cargo')       AS cargo,
        -- gestor (id durável): superior da Gestão > último gestor do Ponto
        COALESCE(gd.colaborador_id, lv.id::bigint)          AS gestor_id,
        CASE WHEN gd.colaborador_id IS NOT NULL THEN 'GESTAO'
             WHEN lv.id IS NOT NULL THEN 'PONTO' ELSE 'SEM GESTOR' END AS gestor_fonte,
        COALESCE(v.data_admissao, c.data_admissao)          AS data_admissao,
        COALESCE(v.data_demissao, c.data_demissao)          AS data_demissao,
        CASE WHEN v.id IS NOT NULL THEN v.demitido
             ELSE (NOT COALESCE(c.ativo, false)) OR c.data_demissao IS NOT NULL END AS demitido,
        v.motivo_demissao                                   AS motivo_demissao_codigo,   -- código do Ponto
        NULLIF(trim(c.motivo_demissao), '')                 AS motivo_demissao_gestao,   -- texto da Gestão
        COALESCE(v.registra_ponto, false)                   AS registra_ponto
    FROM pessoa p
    LEFT JOIN versao_gestao vg            ON vg.gestao_id = p.gestao_id
    LEFT JOIN vinculo v                   ON v.id = p.funcionario_id
    LEFT JOIN solides.colaborador c       ON c.id = p.gestao_id
    LEFT JOIN solides.empresa e           ON e.id = v.empresa_id
    LEFT JOIN solides.empresa eu          ON v.id IS NULL AND upper(eu.nome_fantasia) = upper(trim(c.unidade_nome))
    LEFT JOIN solides.departamento dv     ON dv.id = vg.departamento_id
    LEFT JOIN setor_area sa               ON sa.setor_id = v.setor_id
    LEFT JOIN solides.departamento dsa    ON dsa.id = sa.departamento_id
    LEFT JOIN solides.setor s             ON s.id = v.setor_id
    LEFT JOIN solides.cargo cg            ON cg.id = v.cargo_id
    LEFT JOIN gestor_duravel gd           ON gd.gestao_id = vg.gestor_id
    LEFT JOIN solides.lider l             ON l.id = v.ultimo_gestor_id           -- ultimo_gestor_id -> lider.id
    LEFT JOIN vinculo lv                  ON lv.id = l.funcionario_id            -- lider.funcionario_id -> funcionario.id
)
SELECT
    (CASE WHEN b.colaborador_id < 0 THEN -1 ELSE 1 END)
      * (abs(b.colaborador_id) * 100000 + (b.valido_de - DATE '1900-01-01'))  AS colaborador_key,
    b.colaborador_id,
    b.funcionario_id                                       AS funcionario_id_ponto,
    b.gestao_id                                            AS colaborador_id_gestao,
    ROW_NUMBER() OVER (PARTITION BY b.colaborador_id ORDER BY b.valido_de)    AS versao,
    b.valido_de,
    b.valido_ate,
    (b.valido_ate = DATE '9999-12-31')                     AS atual,
    b.fonte_versao,
    b.origem,
    b.nome,
    b.empresa,
    b.area,
    b.area_fonte,
    b.setor,
    b.cargo,
    b.gestor_id,
    gn.nome                                                AS gestor_nome,
    b.gestor_fonte,
    CASE WHEN b.demitido THEN 'Desligado' ELSE 'Ativo' END AS situacao,
    b.data_admissao,
    b.data_demissao,
    COALESCE(b.motivo_demissao_gestao, b.motivo_demissao_codigo) AS motivo_demissao,
    b.motivo_demissao_codigo,
    -- regra de negócio: classificação do desligamento (códigos do Sólides Ponto)
    CASE b.motivo_demissao_codigo
         WHEN 'PEDIDO_DEMISSAO_COLABORADOR' THEN 'Voluntário'
         WHEN 'DEMISSAO_EMPRESA'            THEN 'Involuntário'
         WHEN 'OUTROS'                      THEN 'Outros'
         ELSE CASE WHEN b.demitido THEN 'Não informado' END
    END                                                    AS tipo_desligamento,
    b.registra_ponto
FROM base b
LEFT JOIN nome_pessoa gn ON gn.colaborador_id = b.gestor_id
UNION ALL
SELECT -1, -1, NULL, NULL, 1, DATE '1900-01-01', DATE '9999-12-31', true, 'FIXO', 'NAO IDENTIFICADO',
       'Não identificado', 'Não identificada', 'Sem área', 'SEM AREA', 'Sem setor', 'Sem cargo',
       NULL, NULL, 'SEM GESTOR', 'Não identificado', NULL, NULL, NULL, NULL, NULL, false;


-- dim_ciclo_avaliacao: 1 linha por ciclo (solicitation) da AVD V3.
CREATE MATERIALIZED VIEW solides_bi.dim_ciclo_avaliacao AS
WITH parametro AS (SELECT 427802 AS ciclo_teste)              -- "Teste-Douglas SGQ" (rascunho)
SELECT
    c.id                                  AS ciclo_key,
    c.nome                                AS ciclo,
    c.status,
    c.data_inicio,
    c.data_fim,
    -- regra de negócio: tipo pelo nome do ciclo (validar nomes novos com o RH)
    CASE WHEN c.id = p.ciclo_teste OR c.status = 'draft' OR c.nome ILIKE 'teste%' THEN 'Teste'
         WHEN c.nome ILIKE '%experi%'                                          THEN 'Experiência'
         WHEN c.nome ILIKE '%desempenho%' OR c.nome ILIKE '%trimestr%'          THEN 'Desempenho trimestral'
         ELSE 'Outro' END                 AS tipo_ciclo,
    -- escalas diferentes: Experiência 1-5, Desempenho 1-4. Nunca tirar média de notas entre tipos.
    CASE WHEN c.nome ILIKE '%experi%' THEN 5 ELSE 4 END         AS escala_max,
    CASE WHEN c.nome ILIKE '%experi%' THEN '1-5' ELSE '1-4' END AS escala,
    EXTRACT(YEAR FROM COALESCE(c.data_fim, c.data_inicio))::int || '-T'
        || EXTRACT(QUARTER FROM COALESCE(c.data_fim, c.data_inicio))::int AS ano_trimestre_ref
FROM solides.avaliacao_ciclo c
CROSS JOIN parametro p;


-- dim_tipo_ocorrencia: 1 linha por (tipo, classificação), com trim ('Suspensão ' vem com espaço).
-- tipo_ocorrencia_key: inteiro estável derivado do md5 de "tipo|classificação" (a fato usa a mesma expressão).
CREATE MATERIALIZED VIEW solides_bi.dim_tipo_ocorrencia AS
WITH base AS (
    SELECT DISTINCT NULLIF(trim(o.tipo), '') AS tipo, NULLIF(trim(o.classificacao), '') AS classificacao
    FROM solides.ocorrencia o
)
SELECT
    ('x' || substr(md5(COALESCE(b.tipo, '') || '|' || COALESCE(b.classificacao, '')), 1, 15))::bit(60)::bigint
                                          AS tipo_ocorrencia_key,
    COALESCE(b.tipo, 'Não informado')          AS tipo,
    COALESCE(b.classificacao, 'Não informada') AS classificacao,
    -- regra de negócio (aprovada pelo André, 24/10): a classificação 'Negativo' só existe nas medidas
    -- disciplinares. Medida = Advertência | Suspensão | Outros (qualquer outro tipo com 'Negativo').
    -- Feedback = Positivo | Neutro | Para melhorar (fecha 100%). O resto (ex.: Recontratação) = Outros.
    CASE WHEN b.tipo = 'Feedback' THEN 'Feedback'
         WHEN b.tipo IN ('Advertência', 'Suspensão') OR b.classificacao = 'Negativo' THEN 'Medida disciplinar'
         ELSE 'Outros' END                AS grupo,
    CASE WHEN b.tipo = 'Feedback' THEN COALESCE(b.classificacao, 'Não informada') END AS tipo_feedback,
    CASE WHEN b.tipo = 'Advertência' THEN 'Advertência'
         WHEN b.tipo = 'Suspensão'   THEN 'Suspensão'
         WHEN b.classificacao = 'Negativo' AND b.tipo IS DISTINCT FROM 'Feedback' THEN 'Outros'
    END                                   AS tipo_medida
FROM base b;


-- =====================================================================================
-- FATOS
-- =====================================================================================

-- fato_ponto_diario: 1 linha por vínculo por dia apurado, dentro da vigência do vínculo
-- (admissão <= dia <= demissão) e só de quem registra ponto (funcionario.registra_ponto).
--   * Até 31/08/2026: legado solides.ponto_consolidado_diario, sem linhas is_ajuste (quitações de
--     banco de horas). As duplicatas de 21-29/08 foram apagadas pelo Otto em 24/10; o DISTINCT ON
--     (maior id) fica só como proteção, caso a carga do Marcos volte a duplicar.
--   * A partir de 01/09/2026: solides.ponto_saldo_diario (API /v2/balance/summary).
-- Hora extra (confirmada pelo RH em 26/10): HE = só a HE 100% paga
--   (domingo/feriado). Legado: hora_extra_tipo3_min (real). Fonte nova (sem HE): regra A =
--   trabalhado - previsto - saldo do dia, em domingo/feriado (reproduz o tipo3 em jan-ago).
--   O excedente de dia útil (excedente_util_min) NÃO é HE: vai para o banco de horas. A troca de regra
--   fica num parâmetro de vw_ponto.
-- Saldo do banco: só a fonte nova traz o acumulado (saldo_banco_min). É semiaditivo: use as linhas
--   com ultimo_dia_mes = true (último dia apurado do colaborador no mês).
--   Conferido: soma de saldo_dia_min no mês = variação do acumulado (set e out/2026, 100% dos colaboradores).
CREATE MATERIALIZED VIEW solides_bi.fato_ponto_diario AS
WITH parametro AS (
    SELECT DATE '2026-08-31' AS fim_legado,       -- 01/09 veio processado pela metade no legado
           DATE '2026-09-01' AS inicio_novo
),
legado AS (
    SELECT DISTINCT ON (l.funcionario_id, l.data_apuracao)
           l.funcionario_id,
           l.data_apuracao                       AS data,
           COALESCE(l.horas_previstas_min, 0)    AS previsto_min,
           COALESCE(l.horas_trabalhadas_min, 0)  AS trabalhado_min,
           COALESCE(l.saldo_horas_min, 0)        AS saldo_dia_min,
           NULL::int                             AS saldo_banco_min,
           COALESCE(l.hora_extra_tipo3_min, 0)   AS he_tipo3_min,
           'LEGADO'::text                        AS fonte
    FROM solides.ponto_consolidado_diario l
    CROSS JOIN parametro p
    WHERE NOT l.is_ajuste                                  -- quitações de banco não são jornada
      AND l.data_apuracao <= p.fim_legado
    ORDER BY l.funcionario_id, l.data_apuracao, l.id DESC  -- duplicatas: fica a de maior id
),
novo AS (
    SELECT n.funcionario_id,
           n.data_apuracao                       AS data,
           COALESCE(n.horas_previstas_min, 0)    AS previsto_min,
           COALESCE(n.horas_trabalhadas_min, 0)  AS trabalhado_min,
           COALESCE(n.saldo_horas_min, 0)        AS saldo_dia_min,
           n.saldo_banco_horas_acumulado_min     AS saldo_banco_min,
           NULL::int                             AS he_tipo3_min,
           'API_SALDO'::text                     AS fonte
    FROM solides.ponto_saldo_diario n
    CROSS JOIN parametro p
    WHERE n.data_apuracao >= p.inicio_novo
),
unido AS (
    SELECT * FROM legado
    UNION ALL
    SELECT * FROM novo
),
base AS (
    SELECT u.*,
           d.colaborador_key,
           d.gestor_id,
           (cal.dia_semana_iso = 7 OR cal.feriado) AS domingo_feriado
    FROM unido u
    JOIN solides_bi.dim_colaborador d
      ON d.colaborador_id = u.funcionario_id
     AND u.data BETWEEN d.valido_de AND d.valido_ate
    JOIN solides_bi.dim_calendario cal ON cal.data = u.data
    WHERE u.data >= d.data_admissao
      AND (d.data_demissao IS NULL OR u.data <= d.data_demissao)   -- legado: 12.364 linhas pós-desligamento
      AND d.registra_ponto                                          -- legado: 8.835 linhas de quem não registra
)
SELECT
    b.data,
    b.colaborador_key,
    COALESCE(g.colaborador_key, -1)                       AS gestor_key,
    b.previsto_min,
    b.trabalhado_min,
    -- AUSÊNCIA (regra do RH): previsto - trabalhado, só quando trabalhou menos que o previsto
    GREATEST(b.previsto_min - b.trabalhado_min, 0)        AS ausencia_min,
    -- alternativa líquida (respeita abonos e tolerância lançados no Sólides): saldo negativo do dia
    GREATEST(-b.saldo_dia_min, 0)                         AS ausencia_liquida_min,
    -- horas normais = parte do trabalhado que cabe no previsto (denominador do HE %)
    LEAST(b.trabalhado_min, b.previsto_min)               AS horas_normais_min,
    -- EXCEDENTE de jornada (vira crédito no banco de horas)
    GREATEST(b.trabalhado_min - b.previsto_min, 0)        AS excedente_min,
    -- excedente só de dia útil (fora domingo/feriado): é o que vai para o banco de horas
    CASE WHEN b.domingo_feriado THEN 0
         ELSE GREATEST(b.trabalhado_min - b.previsto_min, 0) END AS excedente_util_min,
    -- HE 100% PAGA (domingo/feriado): real no legado (tipo3). Na fonte nova (sem HE), regra A da Vera
    -- (aprovada pelo André em 26/10/2026): o que foi trabalhado em domingo/feriado e NÃO foi para o banco
    -- (trabalhado - previsto - saldo do dia). Reproduz o tipo3 do legado com diferença de até 3 h/mês.
    CASE WHEN b.fonte = 'LEGADO' THEN b.he_tipo3_min
         WHEN b.domingo_feriado THEN GREATEST(b.trabalhado_min - b.previsto_min - b.saldo_dia_min, 0)
         ELSE 0 END                                       AS he_paga_min,
    CASE WHEN b.fonte = 'LEGADO' THEN 'Real (tipo3)' ELSE 'Saldo do dia (dom/feriado)' END AS he_paga_fonte,
    b.domingo_feriado,
    b.saldo_dia_min,
    b.saldo_banco_min,                                    -- acumulado do banco (só a partir de 01/09/2026)
    (b.data = MAX(b.data) OVER (PARTITION BY b.funcionario_id, date_trunc('month', b.data))) AS ultimo_dia_mes,
    (b.previsto_min > 0 AND b.trabalhado_min = 0)         AS dia_sem_marcacao,
    b.fonte
FROM base b
LEFT JOIN solides_bi.dim_colaborador g
       ON g.colaborador_id = b.gestor_id
      AND b.data BETWEEN g.valido_de AND g.valido_ate;


-- fato_headcount_mensal: 1 linha por vínculo do Ponto por mês em que esteve ativo (>= 1 dia), desde 01/2026.
-- Ativo no dia D: admissão <= D <= demissão (o dia do desligamento conta).
-- Headcount médio do mês = SUM(dias_ativos) / dias_periodo (média diária). Mês corrente: período até hoje.
-- colaborador_key e gestor_key: versão vigente no último dia ativo do mês.
CREATE MATERIALIZED VIEW solides_bi.fato_headcount_mensal AS
WITH parametro AS (SELECT DATE '2026-01-01' AS inicio_serie),   -- o Ponto só tem desligados desde 12/2025
meses AS (
    SELECT m::date AS mes_ref,
           LEAST((m + interval '1 month - 1 day')::date, DATE '2026-10-31') AS fim_periodo
    FROM parametro p,
         generate_series(p.inicio_serie, date_trunc('month', DATE '2026-10-31')::date, interval '1 month') AS m
),
vinculo AS (
    SELECT d.colaborador_id, d.data_admissao, d.data_demissao
    FROM solides_bi.dim_colaborador d
    WHERE d.atual AND d.funcionario_id_ponto IS NOT NULL
),
base AS (
    SELECT m.mes_ref, m.fim_periodo, v.*,
           LEAST(m.fim_periodo, COALESCE(v.data_demissao, m.fim_periodo)) AS data_ref
    FROM meses m
    JOIN vinculo v
      ON v.data_admissao <= m.fim_periodo
     AND COALESCE(v.data_demissao, DATE '9999-12-31') >= m.mes_ref
)
SELECT
    b.mes_ref,
    d.colaborador_key,
    COALESCE(g.colaborador_key, -1)                       AS gestor_key,
    b.colaborador_id,                                     -- chave durável (contagem distinta de pessoas)
    (b.fim_periodo - b.mes_ref + 1)                       AS dias_periodo,
    (LEAST(COALESCE(b.data_demissao, DATE '9999-12-31'), b.fim_periodo)
       - GREATEST(b.data_admissao, b.mes_ref) + 1)        AS dias_ativos,
    CASE WHEN b.data_admissao <= b.mes_ref
          AND COALESCE(b.data_demissao, DATE '9999-12-31') >= b.mes_ref THEN 1 ELSE 0 END AS ativo_inicio,
    CASE WHEN b.data_admissao <= b.fim_periodo
          AND COALESCE(b.data_demissao, DATE '9999-12-31') >= b.fim_periodo THEN 1 ELSE 0 END AS ativo_fim
FROM base b
JOIN solides_bi.dim_colaborador d
  ON d.colaborador_id = b.colaborador_id
 AND b.data_ref BETWEEN d.valido_de AND d.valido_ate
LEFT JOIN solides_bi.dim_colaborador g
       ON g.colaborador_id = d.gestor_id
      AND b.data_ref BETWEEN g.valido_de AND g.valido_ate;


-- fato_movimentacao: 1 linha por admissão ou desligamento de vínculo do Ponto, desde 01/2026.
-- Transferência entre empresas do grupo (mesmo CPF readmitido até 1 dia depois) fica marcada e
-- não conta em qtd_admissao/qtd_desligamento (hoje 0 casos). Registro TESTE_SISTEMA excluído.
CREATE MATERIALIZED VIEW solides_bi.fato_movimentacao AS
WITH parametro AS (SELECT DATE '2026-01-01' AS inicio_serie),
vinculo AS (
    SELECT f.id::bigint AS colaborador_id,
           lpad(NULLIF(regexp_replace(COALESCE(f.cpf, ''), '\D', '', 'g'), ''), 11, '0') AS cpf,
           f.data_admissao,
           f.data_demissao
    FROM solides.funcionario f
    WHERE COALESCE(f.motivo_demissao, '') <> 'TESTE_SISTEMA'
),
movimento AS (
    SELECT v.colaborador_id, 'Admissão'::text AS tipo_movimentacao, v.data_admissao AS data_movimentacao,
           v.data_admissao, v.data_demissao,
           EXISTS (SELECT 1 FROM vinculo v2
                   WHERE v2.cpf = v.cpf AND v2.colaborador_id <> v.colaborador_id
                     AND v.data_admissao BETWEEN v2.data_demissao AND v2.data_demissao + 1) AS transferencia
    FROM vinculo v
    UNION ALL
    SELECT v.colaborador_id, 'Desligamento'::text, v.data_demissao,
           v.data_admissao, v.data_demissao,
           EXISTS (SELECT 1 FROM vinculo v2
                   WHERE v2.cpf = v.cpf AND v2.colaborador_id <> v.colaborador_id
                     AND v2.data_admissao BETWEEN v.data_demissao AND v.data_demissao + 1)
    FROM vinculo v
    WHERE v.data_demissao IS NOT NULL
)
SELECT
    m.data_movimentacao,
    d.colaborador_key,
    COALESCE(g.colaborador_key, -1)                       AS gestor_key,
    m.tipo_movimentacao,                                  -- Admissão | Desligamento
    CASE WHEN m.tipo_movimentacao = 'Desligamento' THEN d.motivo_demissao END        AS motivo,
    CASE WHEN m.tipo_movimentacao = 'Desligamento' THEN d.motivo_demissao_codigo END AS motivo_codigo,
    CASE WHEN m.tipo_movimentacao = 'Desligamento' THEN d.tipo_desligamento END      AS tipo_desligamento,
    CASE WHEN m.tipo_movimentacao = 'Desligamento' THEN m.data_demissao - m.data_admissao END AS tempo_casa_dias,
    CASE WHEN m.tipo_movimentacao <> 'Desligamento' THEN NULL
         WHEN m.data_demissao - m.data_admissao <= 90  THEN '0-3 meses'
         WHEN m.data_demissao - m.data_admissao <= 180 THEN '3-6 meses'
         WHEN m.data_demissao - m.data_admissao <= 365 THEN '6-12 meses'
         WHEN m.data_demissao - m.data_admissao <= 730 THEN '1-2 anos'
         ELSE '2+ anos' END                               AS faixa_tempo_casa,
    m.transferencia,
    -- 8 desligamentos até 1 dia após a admissão: possíveis cadastros de teste (validar com o RH)
    (m.tipo_movimentacao = 'Desligamento' AND m.data_demissao - m.data_admissao <= 1) AS suspeita_cadastro_teste,
    CASE WHEN m.tipo_movimentacao = 'Admissão'     AND NOT m.transferencia THEN 1 ELSE 0 END AS qtd_admissao,
    CASE WHEN m.tipo_movimentacao = 'Desligamento' AND NOT m.transferencia THEN 1 ELSE 0 END AS qtd_desligamento
FROM movimento m
CROSS JOIN parametro p
JOIN solides_bi.dim_colaborador d
  ON d.colaborador_id = m.colaborador_id
 AND m.data_movimentacao BETWEEN d.valido_de AND d.valido_ate
LEFT JOIN solides_bi.dim_colaborador g
       ON g.colaborador_id = d.gestor_id
      AND m.data_movimentacao BETWEEN g.valido_de AND g.valido_ate
WHERE m.data_movimentacao >= p.inicio_serie;


-- fato_vaga: 1 linha por vaga do Sólides Gestão (accumulating snapshot).
-- Fechamento = data de data_status (status_updated_at da API) quando status = 'concluido'.
-- data_prazo (finalDate) é PRAZO, não fechamento. SLA = fechamento - abertura, em dias corridos.
-- Abertas: fora da média do SLA, com dias_em_aberto até hoje. Canceladas: fora do SLA.
-- tipo_vaga: classificação PROVISÓRIA por palavra-chave no cargo (a API não traz o tipo pedido pelo RH).
--   Ordem: Liderança > Técnico > Administrativo > Operacional (nomes do documento do RH). Trocar por um de-para do RH.
CREATE MATERIALIZED VIEW solides_bi.fato_vaga AS
WITH src AS (
    SELECT v.*,
           (v.data_status AT TIME ZONE 'America/Sao_Paulo')::date AS data_status_local
    FROM solides.vaga v
),
calc AS (
    SELECT s.*,
           CASE WHEN s.status = 'concluido' AND s.data_status_local >= s.data_abertura
                THEN s.data_status_local END AS data_fechamento
    FROM src s
)
SELECT
    c.id                                         AS vaga_id,
    c.data_abertura,
    c.data_fechamento,
    c.data_prazo,
    CASE WHEN c.status = 'cancelado' THEN c.data_status_local END AS data_cancelamento,
    c.titulo,
    c.cargo,
    c.tipo                                       AS publicacao,          -- Pública | Oculta
    CASE
        WHEN c.cargo ~* '\m(coordenador|supervisor|gerente|diretor|l[ií]der|head|encarregad)' THEN 'Liderança'
        WHEN c.cargo ~* '(t[ée]cnic|instalador|desenvolvedor|programador|infraestrutura|\mrede\M|eletr[ôo]nica|inform[áa]tica)' THEN 'Técnico'
        WHEN c.cargo ~* '(assistente|analista|controller|administrativ|financeir|almoxarifado|\mrh\M|\mdp\M|marketing|compra|designer|jur[ií]dic|cont[áa]bil)' THEN 'Administrativo'
        WHEN c.cargo ~* '(atendente|vendedor|agente|auxiliar|operador|promotor|consultor|executivo|despachante|monitor|multiplicador|manuten)' THEN 'Operacional'
        ELSE 'Não classificado'
    END                                          AS tipo_vaga,
    c.status,
    CASE c.status WHEN 'concluido' THEN 'Fechada' WHEN 'em_andamento' THEN 'Aberta'
                  WHEN 'cancelado' THEN 'Cancelada' ELSE c.status END AS situacao,
    (c.data_fechamento - c.data_abertura)        AS sla_dias,
    CASE WHEN c.status = 'em_andamento' THEN DATE '2026-10-31' - c.data_abertura END AS dias_em_aberto,
    CASE WHEN c.data_fechamento IS NOT NULL THEN (c.data_fechamento <= c.data_prazo) END AS fechada_no_prazo,
    c.qtd_posicoes,
    c.qtd_posicoes_ocupadas,
    CASE WHEN c.status = 'em_andamento' THEN 1 ELSE 0 END AS qtd_aberta,
    CASE WHEN c.status = 'concluido'    THEN 1 ELSE 0 END AS qtd_fechada,
    CASE WHEN c.status = 'cancelado'    THEN 1 ELSE 0 END AS qtd_cancelada,
    c.cidade,
    c.uf
FROM calc c;


-- fato_ocorrencia: 1 linha por ocorrência do Sólides Gestão (feedback, advertência, suspensão...).
-- Colaborador: vínculo do Ponto (mesmo CPF) vigente na data. Sem vínculo: pessoa só da Gestão.
-- Sem cadastro: -1. gestor_key = gestor do colaborador na data (a API não diz quem aplicou).
-- Datas com ano < 2000 ou mais de 31 dias no futuro viram NULL (data_valida = false, 8 casos).
CREATE MATERIALIZED VIEW solides_bi.fato_ocorrencia AS
WITH src AS (
    SELECT o.id AS ocorrencia_id,
           o.colaborador_id AS gestao_id,
           NULLIF(trim(o.tipo), '') AS tipo,
           NULLIF(trim(o.classificacao), '') AS classificacao,
           CASE WHEN o.data_ocorrencia BETWEEN DATE '2000-01-01' AND DATE '2026-10-31' + 31
                THEN o.data_ocorrencia END AS data_ocorrencia
    FROM solides.ocorrencia o
),
resolvido AS (
    SELECT s.*, COALESCE(pc.colaborador_id, -1) AS colaborador_id
    FROM src s
    LEFT JOIN LATERAL (
        SELECT p.colaborador_id
        FROM solides_bi.aux_ponte_colaborador p
        WHERE p.gestao_id = s.gestao_id
        ORDER BY (s.data_ocorrencia BETWEEN p.data_admissao
                                        AND COALESCE(p.data_demissao, DATE '9999-12-31')) DESC NULLS LAST,
                 p.data_admissao DESC NULLS LAST
        LIMIT 1
    ) pc ON true
)
SELECT
    r.ocorrencia_id,
    r.data_ocorrencia,
    (r.data_ocorrencia IS NOT NULL)                        AS data_valida,
    COALESCE(d.colaborador_key, -1)                        AS colaborador_key,
    r.colaborador_id,                                      -- chave durável (contagem distinta de pessoas)
    COALESCE(g.colaborador_key, -1)                        AS gestor_key,
    ('x' || substr(md5(COALESCE(r.tipo, '') || '|' || COALESCE(r.classificacao, '')), 1, 15))::bit(60)::bigint
                                                           AS tipo_ocorrencia_key,
    1                                                      AS qtd
FROM resolvido r
LEFT JOIN solides_bi.dim_colaborador d
       ON d.colaborador_id = r.colaborador_id
      AND COALESCE(r.data_ocorrencia, DATE '2026-10-31') BETWEEN d.valido_de AND d.valido_ate
LEFT JOIN solides_bi.dim_colaborador g
       ON g.colaborador_id = d.gestor_id
      AND COALESCE(r.data_ocorrencia, DATE '2026-10-31') BETWEEN g.valido_de AND g.valido_ate;


-- fato_avaliacao: 1 linha por avaliação x critério (AVD V3). Avaliação sem critério (não respondida)
-- gera 1 linha com critério nulo, para entrar no denominador do % concluídas.
-- Só a última versão de cada (ciclo, avaliador, avaliado). Ciclos de Teste ficam de fora.
-- qtd_avaliacao / qtd_respondida = 1 só na 1ª linha de cada avaliação (somáveis sem DISTINCTCOUNT).
-- gestor_key = AVALIADOR (quem precisa concluir). O gestor de cadastro está em dim_colaborador.gestor_nome.
-- data_referencia = data da avaliação, ou o fim do ciclo quando não respondida.
CREATE MATERIALIZED VIEW solides_bi.fato_avaliacao AS
WITH ciclo AS (
    SELECT * FROM solides_bi.dim_ciclo_avaliacao WHERE tipo_ciclo <> 'Teste'
),
avaliacao AS (
    SELECT DISTINCT ON (a.avaliacao_ciclo_id, a.avaliador_id, a.avaliado_id) a.*
    FROM solides.avaliacao a
    ORDER BY a.avaliacao_ciclo_id, a.avaliador_id, a.avaliado_id, a.versao DESC
),
linha AS (
    SELECT a.avaliacao_ciclo_id, a.avaliador_id, a.avaliado_id, a.versao, a.respondida,
           a.departamento_avaliado,
           COALESCE(a.data_avaliacao, ci.data_fim, ci.data_inicio) AS data_referencia,
           a.data_avaliacao,
           ci.escala_max,
           cr.criterio_id, cr.criterio_tipo, cr.criterio_descricao, cr.nota, cr.peso,
           ROW_NUMBER() OVER (PARTITION BY a.avaliacao_ciclo_id, a.avaliador_id, a.avaliado_id
                              ORDER BY cr.criterio_id NULLS LAST) AS n_linha,
           COUNT(cr.nota) OVER (PARTITION BY a.avaliacao_ciclo_id, a.avaliador_id, a.avaliado_id) AS qtd_notas
    FROM avaliacao a
    JOIN ciclo ci ON ci.ciclo_key = a.avaliacao_ciclo_id
    LEFT JOIN solides.avaliacao_criterio cr
           ON cr.avaliacao_ciclo_id = a.avaliacao_ciclo_id
          AND cr.avaliador_id       = a.avaliador_id
          AND cr.avaliado_id        = a.avaliado_id
          AND cr.versao             = a.versao
),
resolvido AS (
    SELECT l.*,
           COALESCE(pa.colaborador_id, -1) AS colaborador_id,
           COALESCE(pv.colaborador_id, -1) AS avaliador_colaborador_id,
           (COALESCE(l.respondida, false) OR l.qtd_notas > 0) AS foi_respondida
    FROM linha l
    LEFT JOIN LATERAL (
        SELECT p.colaborador_id FROM solides_bi.aux_ponte_colaborador p
        WHERE p.gestao_id = l.avaliado_id
        ORDER BY (l.data_referencia BETWEEN p.data_admissao
                                        AND COALESCE(p.data_demissao, DATE '9999-12-31')) DESC NULLS LAST,
                 p.data_admissao DESC NULLS LAST
        LIMIT 1
    ) pa ON true
    LEFT JOIN LATERAL (
        SELECT p.colaborador_id FROM solides_bi.aux_ponte_colaborador p
        WHERE p.gestao_id = l.avaliador_id
        ORDER BY (l.data_referencia BETWEEN p.data_admissao
                                        AND COALESCE(p.data_demissao, DATE '9999-12-31')) DESC NULLS LAST,
                 p.data_admissao DESC NULLS LAST
        LIMIT 1
    ) pv ON true
)
SELECT
    r.avaliacao_ciclo_id || '-' || r.avaliador_id || '-' || r.avaliado_id AS avaliacao_id,
    r.avaliacao_ciclo_id                                  AS ciclo_key,
    r.data_referencia,
    r.data_avaliacao,
    COALESCE(d.colaborador_key, -1)                       AS colaborador_key,      -- avaliado
    r.colaborador_id,                                     -- chave durável do avaliado
    COALESCE(g.colaborador_key, -1)                       AS gestor_key,           -- avaliador
    r.versao,
    r.foi_respondida                                      AS respondida,
    r.criterio_id,
    r.criterio_tipo,
    r.criterio_descricao,
    r.nota,                                               -- 1-4 (Desempenho) ou 1-5 (Experiência): não misturar
    r.peso,
    ((r.nota - 1) / NULLIF(r.escala_max - 1, 0) * 100)::numeric(5,1) AS nota_pct,   -- 0-100%
    r.departamento_avaliado,                              -- área informada na AVD (texto)
    CASE WHEN r.n_linha = 1 THEN 1 ELSE 0 END             AS qtd_avaliacao,
    CASE WHEN r.n_linha = 1 AND r.foi_respondida THEN 1 ELSE 0 END AS qtd_respondida
FROM resolvido r
LEFT JOIN solides_bi.dim_colaborador d
       ON d.colaborador_id = r.colaborador_id
      AND COALESCE(r.data_referencia, DATE '2026-10-31') BETWEEN d.valido_de AND d.valido_ate
LEFT JOIN solides_bi.dim_colaborador g
       ON g.colaborador_id = r.avaliador_colaborador_id
      AND COALESCE(r.data_referencia, DATE '2026-10-31') BETWEEN g.valido_de AND g.valido_ate;


-- =====================================================================================
-- ÍNDICES das views materializadas
-- Os UNIQUE permitem REFRESH ... CONCURRENTLY (o dashboard continua lendo durante a atualização).
-- fato_avaliacao não tem chave única só de colunas (avaliação não respondida tem critério nulo):
-- é atualizada sem CONCURRENTLY (bloqueio de leitura de menos de 1 s, ~6 mil linhas).
-- =====================================================================================
CREATE UNIQUE INDEX aux_ponte_colaborador_uk   ON solides_bi.aux_ponte_colaborador (gestao_id, colaborador_id);
CREATE INDEX        aux_ponte_colaborador_func ON solides_bi.aux_ponte_colaborador (funcionario_id);
CREATE UNIQUE INDEX dim_calendario_uk          ON solides_bi.dim_calendario (data);
CREATE UNIQUE INDEX dim_colaborador_uk         ON solides_bi.dim_colaborador (colaborador_key);
CREATE INDEX        dim_colaborador_vigencia   ON solides_bi.dim_colaborador (colaborador_id, valido_de, valido_ate);
CREATE UNIQUE INDEX dim_ciclo_avaliacao_uk     ON solides_bi.dim_ciclo_avaliacao (ciclo_key);
CREATE UNIQUE INDEX dim_tipo_ocorrencia_uk     ON solides_bi.dim_tipo_ocorrencia (tipo_ocorrencia_key);
CREATE UNIQUE INDEX fato_ponto_diario_uk       ON solides_bi.fato_ponto_diario (data, colaborador_key);
CREATE INDEX        fato_ponto_diario_colab    ON solides_bi.fato_ponto_diario (colaborador_key);
CREATE UNIQUE INDEX fato_headcount_mensal_uk   ON solides_bi.fato_headcount_mensal (mes_ref, colaborador_id);
CREATE UNIQUE INDEX fato_movimentacao_uk       ON solides_bi.fato_movimentacao (data_movimentacao, colaborador_key, tipo_movimentacao);
CREATE UNIQUE INDEX fato_vaga_uk               ON solides_bi.fato_vaga (vaga_id);
CREATE UNIQUE INDEX fato_ocorrencia_uk         ON solides_bi.fato_ocorrencia (ocorrencia_id);
CREATE INDEX        fato_ocorrencia_colab      ON solides_bi.fato_ocorrencia (colaborador_key);
CREATE INDEX        fato_avaliacao_ciclo       ON solides_bi.fato_avaliacao (ciclo_key, colaborador_key);

-- Atualização, na ordem das dependências (apoio > dimensões > fatos). Rodar depois de cada carga.
CREATE OR REPLACE FUNCTION solides_bi.atualizar() RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
    inicio timestamptz := clock_timestamp();
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.aux_ponte_colaborador;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.dim_calendario;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.dim_colaborador;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.dim_ciclo_avaliacao;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.dim_tipo_ocorrencia;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.fato_ponto_diario;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.fato_headcount_mensal;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.fato_movimentacao;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.fato_vaga;
    REFRESH MATERIALIZED VIEW CONCURRENTLY solides_bi.fato_ocorrencia;
    REFRESH MATERIALIZED VIEW solides_bi.fato_avaliacao;
    RETURN 'solides_bi atualizado em ' || round(extract(epoch FROM clock_timestamp() - inicio)::numeric, 1) || ' s';
END
$fn$;

COMMENT ON FUNCTION solides_bi.atualizar() IS 'Atualiza as views materializadas do Dashboard GCE na ordem certa. Rodar depois de cada carga da staging (schema solides).';


-- -------------------------------------------------------------------------------------
-- NINE BOX (fica por último): virá de CSV exportado pelo RH. Quando a tabela bruta existir, entra
-- como 7ª fato (ciclo x colaborador), com ciclo_key e colaborador_key. Não criar antes disso.
-- -------------------------------------------------------------------------------------


-- =====================================================================================
-- METAS (única tabela do schema; o RH preenche)
-- =====================================================================================
-- Nenhum sistema tem metas. 1 linha por indicador por início de vigência. Valores na MESMA unidade do
-- card (ex.: turnover 5 = 5%, banco_horas 10 = 10 h por colaborador, sla_vagas 30 = 30 dias).
-- Status do Painel de Atenção (calculado no backend, depois de agregar):
--   meta/limites NULL                              -> 'Sem meta'
--   menor_melhor: valor >  limite_vermelho -> 'Vermelho' | valor >  limite_amarelo -> 'Amarelo' | senão 'Verde'
--   maior_melhor: valor <  limite_vermelho -> 'Vermelho' | valor <  limite_amarelo -> 'Amarelo' | senão 'Verde'
--   faixa:        |valor| > limite_vermelho -> 'Vermelho' | |valor| > limite_amarelo -> 'Amarelo' | senão 'Verde'
--                 (banco de horas: tanto saldo muito positivo quanto muito negativo é ruim)
-- Metas do RH (Joyce, 26/10/2026). limite_amarelo = a própria meta; limite_vermelho = meta 20% pior
-- (regra padrão proposta pelo André; ajustar aqui se o RH quiser outra faixa).
CREATE TABLE IF NOT EXISTS solides_bi.meta_indicador (
    indicador        text          NOT NULL,
    nome             text          NOT NULL,
    unidade          text          NOT NULL,
    meta             numeric(12,4),
    limite_amarelo   numeric(12,4),
    limite_vermelho  numeric(12,4),
    sentido          text          NOT NULL,
    vigencia_inicio  date          NOT NULL DEFAULT DATE '2026-01-01',
    observacao       text,
    atualizado_em    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT meta_indicador_pk PRIMARY KEY (indicador, vigencia_inicio),
    CONSTRAINT meta_indicador_sentido_ck CHECK (sentido IN ('menor_melhor', 'maior_melhor', 'faixa')),
    CONSTRAINT meta_indicador_unidade_ck CHECK (unidade IN ('%', 'h', 'dias', 'qtd'))
);

COMMENT ON TABLE solides_bi.meta_indicador IS 'Metas e faixas de alerta dos 8 indicadores do Dashboard GCE, preenchidas pelo RH. Grão: indicador x vigencia_inicio (vale a linha de maior vigencia_inicio <= mês). Valores na unidade do card. NULL = sem meta (status "Sem meta").';
COMMENT ON COLUMN solides_bi.meta_indicador.indicador IS 'Código do indicador, igual a vw_indicador_mensal.indicador.';
COMMENT ON COLUMN solides_bi.meta_indicador.meta IS 'Valor-alvo (linha de meta nos gráficos).';
COMMENT ON COLUMN solides_bi.meta_indicador.limite_amarelo IS 'A partir deste valor o status vira Amarelo (no sentido do indicador).';
COMMENT ON COLUMN solides_bi.meta_indicador.limite_vermelho IS 'A partir deste valor o status vira Vermelho (no sentido do indicador).';
COMMENT ON COLUMN solides_bi.meta_indicador.sentido IS 'menor_melhor ou maior_melhor. Usado no status e na área crítica.';

INSERT INTO solides_bi.meta_indicador
    (indicador, nome, unidade, meta, limite_amarelo, limite_vermelho, sentido, vigencia_inicio, observacao) VALUES
    ('turnover',              'Turnover',                     'qtd',   10,   10,   12,   'menor_melhor', DATE '2026-01-01', 'Desligamentos no mês (máximo 10 colaboradores). Corrigido pelo RH (Joyce) em 26/10/2026; antes: 4% do headcount médio'),
    ('absenteismo',           'Absenteísmo',                  '%',      3,    3,    3.6, 'menor_melhor', DATE '2026-01-01', 'Horas ausentes líquidas (com abonos) / horas previstas'),
    ('hora_extra',            'Hora extra',                   '%',      8,    8,    9.6, 'menor_melhor', DATE '2026-01-01', 'HE 100% paga (domingo/feriado) / horas normais. Confirmado pelo RH em 26/10/2026'),
    ('banco_horas',           'Banco de horas (saldo médio)', 'h',      4,    4,    4.8, 'faixa',        DATE '2026-01-01', 'Saldo médio por colaborador entre -4h e +4h'),
    ('sla_vagas',             'Tempo para fechar vagas',      'dias',  25,   25,   30,   'menor_melhor', DATE '2026-01-01', 'Média de dias entre abertura e fechamento das vagas fechadas no mês'),
    ('feedback',              'Cobertura de feedback',        '%',     95,   95,   76,   'maior_melhor', DATE '2026-01-01', '% da equipe que recebeu ao menos 1 feedback no mês'),
    ('medidas_disciplinares', 'Medidas disciplinares',        'qtd',   50,   50,   60,   'menor_melhor', DATE '2026-01-01', 'Quantidade de medidas no mês'),
    ('avd_conclusao',         'AVD concluídas',               '%',    100,  100,   80,   'maior_melhor', DATE '2026-01-01', 'Avaliações finalizadas / avaliações do ciclo de Desempenho trimestral')
ON CONFLICT (indicador, vigencia_inicio) DO NOTHING;


-- =====================================================================================
-- VIEWS DE VISUAL (vw_)  -  consumidas pelo backend Node
-- =====================================================================================
-- Regras gerais:
--   * Filtros: Período e Comparar com = mes_ref | Empresa = empresa | Área = area | Gestor = gestor_id
--     (gestor_nome para exibir). Área e gestor são os do colaborador NA DATA (versão SCD2).
--   * O backend aplica o WHERE, faz SUM dos componentes e só depois divide. Nunca tirar média de razões.
--   * gestor_id = -1 / 'Sem gestor' quando não há gestor. Empresa 'Não identificada', área 'Sem área'.
--   * Vagas não têm empresa, área nem gestor: os filtros de pessoa não se aplicam ao bloco de SLA.

-- vw_turnover: 1 linha por mês x empresa x área x gestor (desde 01/2026). Bloco Turnover + cards de
-- Turnover, Turnover acumulado e Headcount médio.
--   Turnover %       = SUM(desligamentos) / SUM(hc_medio) * 100
--   Headcount médio  = SUM(hc_medio)   (= SUM(dias_ativos) / dias_periodo do mês)
--   Turnover acum. % = SUM(desligamentos de jan..M) / (SUM(dias_ativos de jan..M) / (fim_periodo(M) - 01/01 + 1)) * 100
-- Área/gestor do headcount: versão vigente no último dia ativo do mês. Do desligamento: versão na data.
CREATE OR REPLACE VIEW solides_bi.vw_turnover AS
WITH evento AS (
    SELECT h.mes_ref, h.colaborador_key, h.dias_ativos, h.ativo_inicio, h.ativo_fim,
           0 AS admissoes, 0 AS desligamentos, 0 AS deslig_voluntario, 0 AS deslig_involuntario,
           0 AS deslig_suspeita_teste
    FROM solides_bi.fato_headcount_mensal h
    UNION ALL
    SELECT date_trunc('month', m.data_movimentacao)::date, m.colaborador_key, 0, 0, 0,
           m.qtd_admissao,
           m.qtd_desligamento,
           CASE WHEN m.tipo_desligamento = 'Voluntário'   THEN m.qtd_desligamento ELSE 0 END,
           CASE WHEN m.tipo_desligamento = 'Involuntário' THEN m.qtd_desligamento ELSE 0 END,
           CASE WHEN m.suspeita_cadastro_teste            THEN m.qtd_desligamento ELSE 0 END
    FROM solides_bi.fato_movimentacao m
    WHERE m.data_movimentacao <= DATE '2026-10-31'                  -- desligamento agendado não conta antes da data
)
SELECT
    e.mes_ref,
    d.empresa,
    d.area,
    COALESCE(d.gestor_id, -1)                                  AS gestor_id,
    COALESCE(d.gestor_nome, 'Sem gestor')                      AS gestor_nome,
    -- dias do período: os MESMOS gravados na fato materializada (auditoria da Vera, D3). Calcular aqui com o
    -- "hoje" da consulta misturava datas de momentos diferentes quando a atualização não rodava no dia.
    p.dias_periodo,
    SUM(e.dias_ativos)                                         AS dias_ativos,
    round(SUM(e.dias_ativos)::numeric / p.dias_periodo, 6)    AS hc_medio,
    SUM(e.ativo_inicio)                                        AS hc_inicio,
    SUM(e.ativo_fim)                                           AS hc_fim,
    SUM(e.admissoes)                                           AS admissoes,
    SUM(e.desligamentos)                                       AS desligamentos,
    SUM(e.deslig_voluntario)                                   AS desligamentos_voluntarios,
    SUM(e.deslig_involuntario)                                 AS desligamentos_involuntarios,
    SUM(e.deslig_suspeita_teste)                               AS desligamentos_suspeita_teste
FROM evento e
JOIN solides_bi.dim_colaborador d ON d.colaborador_key = e.colaborador_key
JOIN (SELECT mes_ref, MAX(dias_periodo) AS dias_periodo FROM solides_bi.fato_headcount_mensal GROUP BY 1) p ON p.mes_ref = e.mes_ref
GROUP BY 1, 2, 3, 4, 5, p.dias_periodo;


-- vw_ponto: 1 linha por mês x empresa x área x gestor (desde 01/2026). Blocos Absenteísmo e Hora extra.
--   Absenteísmo %    = SUM(ausencia_min) / SUM(previsto_min) * 100     (líquido: ausencia_liquida_min)
--   HE %             = SUM(he_min) / SUM(horas_normais_min) * 100
--   HE acumulada     = SUM(he_min de jan..M) / 60 (h)  e  SUM(he_min) / SUM(horas_normais_min) de jan..M
-- Troca da regra de HE (pendente RH): mude regra_he no CTE parametro. he_100_min e excedente_util_min
-- também estão expostos, para o backend montar qualquer variante.
CREATE OR REPLACE VIEW solides_bi.vw_ponto AS
WITH parametro AS (
    -- 'DOMINGO_FERIADO'                = só HE 100% paga (decisão de 24/10)
    -- 'DOMINGO_FERIADO_MAIS_EXCEDENTE' = HE 100% + excedente de dia útil
    SELECT 'DOMINGO_FERIADO'::text AS regra_he
)
SELECT
    date_trunc('month', f.data)::date                          AS mes_ref,
    d.empresa,
    d.area,
    COALESCE(d.gestor_id, -1)                                  AS gestor_id,
    COALESCE(d.gestor_nome, 'Sem gestor')                      AS gestor_nome,
    COUNT(*)                                                   AS dias_apurados,
    SUM(f.previsto_min)                                        AS previsto_min,
    SUM(f.trabalhado_min)                                      AS trabalhado_min,
    SUM(f.ausencia_min)                                        AS ausencia_min,
    SUM(f.ausencia_liquida_min)                                AS ausencia_liquida_min,
    SUM(f.horas_normais_min)                                   AS horas_normais_min,
    SUM(f.he_paga_min)                                         AS he_100_min,
    SUM(f.excedente_util_min)                                  AS excedente_util_min,
    SUM(f.he_paga_min
        + CASE WHEN p.regra_he = 'DOMINGO_FERIADO_MAIS_EXCEDENTE' THEN f.excedente_util_min ELSE 0 END) AS he_min,
    MIN(p.regra_he)                                            AS regra_he,
    MIN(f.he_paga_fonte)                                       AS he_fonte
FROM solides_bi.fato_ponto_diario f
JOIN solides_bi.dim_colaborador d ON d.colaborador_key = f.colaborador_key
CROSS JOIN parametro p
GROUP BY 1, 2, 3, 4, 5;


-- vw_banco_horas: 1 linha por colaborador x mês com ponto apurado (desde 01/2026). Bloco Banco de horas.
-- Saldo acumulado só existe a partir de 09/2026 (último dia apurado do colaborador no mês).
-- Saldo e contagens só para quem estava ativo no fim do período (desligado no mês fica fora do saldo).
--   Saldo positivo h    = SUM(saldo_positivo_min) / 60      Saldo negativo h = SUM(saldo_negativo_min) / 60
--   Saldo geral h       = SUM(saldo_min) / 60
--   Saldo médio h       = SUM(saldo_min) / SUM(qtd_com_saldo) / 60   (geral e por área)
--   > +40h / < -40h     = SUM(qtd_acima_40h) / SUM(qtd_abaixo_40h)
--   Evolução mensal     = saldo a partir de 09/2026. Antes: SUM(variacao_mes_min) (variação do mês =
--                         soma do saldo diário de jornada, sem quitações). Em set/out a variação bate
--                         exatamente com a diferença do acumulado.
CREATE OR REPLACE VIEW solides_bi.vw_banco_horas AS
WITH parametro AS (SELECT 2400 AS limite_min),                -- 40 h
base AS (
    SELECT f.data, f.saldo_banco_min, f.ultimo_dia_mes, f.fonte,
           d.colaborador_id, d.empresa, d.area,
           COALESCE(d.gestor_id, -1)                           AS gestor_id,
           COALESCE(d.gestor_nome, 'Sem gestor')               AS gestor_nome,
           d.data_demissao,
           date_trunc('month', f.data)::date                   AS mes_ref,
           SUM(f.saldo_dia_min) OVER (PARTITION BY d.colaborador_id, date_trunc('month', f.data)) AS variacao_mes_min
    FROM solides_bi.fato_ponto_diario f
    JOIN solides_bi.dim_colaborador d ON d.colaborador_key = f.colaborador_key
),
ultimo AS (
    SELECT b.*,
           (b.data_demissao IS NULL
            OR b.data_demissao > LEAST((b.mes_ref + interval '1 month - 1 day')::date, DATE '2026-10-31')) AS ativo_fim,
           CASE WHEN b.data_demissao IS NULL
                  OR b.data_demissao > LEAST((b.mes_ref + interval '1 month - 1 day')::date, DATE '2026-10-31')
                THEN b.saldo_banco_min END                     AS saldo
    FROM base b
    WHERE b.ultimo_dia_mes
)
SELECT
    u.mes_ref,
    u.colaborador_id,
    u.empresa,
    u.area,
    u.gestor_id,
    u.gestor_nome,
    u.data                                                     AS data_saldo,
    CASE WHEN u.ativo_fim THEN 1 ELSE 0 END                    AS ativo_fim_mes,
    u.variacao_mes_min,
    u.saldo                                                    AS saldo_min,
    CASE WHEN u.saldo IS NOT NULL THEN 1 ELSE 0 END            AS qtd_com_saldo,
    CASE WHEN u.saldo > 0 THEN u.saldo ELSE 0 END              AS saldo_positivo_min,
    CASE WHEN u.saldo < 0 THEN u.saldo ELSE 0 END              AS saldo_negativo_min,
    CASE WHEN u.saldo > 0 THEN 1 ELSE 0 END                    AS qtd_positivo,
    CASE WHEN u.saldo < 0 THEN 1 ELSE 0 END                    AS qtd_negativo,
    CASE WHEN u.saldo >  p.limite_min THEN 1 ELSE 0 END        AS qtd_acima_40h,
    CASE WHEN u.saldo < -p.limite_min THEN 1 ELSE 0 END        AS qtd_abaixo_40h,
    u.fonte
FROM ultimo u
CROSS JOIN parametro p;


-- vw_vaga: 1 linha por vaga. Bloco SLA de vagas (sem empresa/área/gestor: a API não traz).
--   SLA médio (dias) do mês  = SUM(sla_dias) / SUM(qtd_fechada)  WHERE mes_fechamento = M
--   Vagas fechadas no mês    = SUM(qtd_fechada) WHERE mes_fechamento = M
--   Vagas abertas (hoje)     = SUM(qtd_aberta)          Fora do SLA (hoje) = SUM(qtd_fora_sla_hoje)
--   Abertas no fim do mês M  = data_abertura <= fim(M) AND (data_saida IS NULL OR data_saida > fim(M))
--   Fora do SLA no fim de M  = abertas no fim de M AND data_prazo < fim(M)
--   Fechadas depois do prazo = SUM(qtd_fechada_apos_prazo) WHERE mes_fechamento = M
--   SLA por tipo de vaga     = mesmas somas agrupadas por tipo_vaga
--   (fim(M) = último dia do mês, ou hoje no mês corrente)
CREATE OR REPLACE VIEW solides_bi.vw_vaga AS
SELECT
    v.vaga_id,
    v.cargo,
    v.tipo_vaga,
    v.situacao,
    v.data_abertura,
    v.data_prazo,
    v.data_fechamento,
    v.data_cancelamento,
    COALESCE(v.data_fechamento, v.data_cancelamento)           AS data_saida,
    date_trunc('month', v.data_abertura)::date                 AS mes_abertura,
    date_trunc('month', v.data_fechamento)::date               AS mes_fechamento,
    v.sla_dias,
    v.dias_em_aberto,
    v.qtd_aberta,
    v.qtd_fechada,
    v.qtd_cancelada,
    CASE WHEN v.status = 'em_andamento' AND v.data_prazo < DATE '2026-10-31' THEN 1 ELSE 0 END AS qtd_fora_sla_hoje,
    CASE WHEN v.data_fechamento > v.data_prazo THEN 1 ELSE 0 END AS qtd_fechada_apos_prazo,
    v.qtd_posicoes,
    v.cidade,
    v.uf
FROM solides_bi.fato_vaga v;


-- vw_ocorrencia_colaborador_mes: 1 linha por colaborador x mês (desde 01/2026) em que ele esteve na
-- equipe (headcount) OU recebeu ocorrência. Blocos Feedback e Medidas disciplinares.
-- Área/gestor: do headcount (último dia ativo do mês); quem não está no headcount (só Gestão ou
-- não identificado, colaborador_id = -1) usa a versão da última ocorrência do mês.
-- O gestor é o gestor do colaborador (a API não informa quem aplicou a ocorrência).
--   Feedbacks no mês        = SUM(feedbacks); por tipo = SUM(feedback_positivo | _neutro | _para_melhorar)
--   Por gestor: Feedbacks   = SUM(feedbacks) | Equipe = SUM(na_equipe) | Cobertura % = SUM(coberto) / SUM(na_equipe) * 100
--   Medidas no mês          = SUM(medidas); por tipo = SUM(medida_advertencia | _suspensao | _outros)
--   Colaboradores envolvidos = SUM(com_medida) no mês | COUNT(DISTINCT colaborador_id) WHERE medidas > 0 no acumulado
--   Com mais de uma medida  = SUM(reincidente_mes) no mês | no acumulado: GROUP BY colaborador_id HAVING SUM(medidas) > 1
--   Medidas acumuladas      = SUM(medidas) de jan..M
-- Ocorrências com data inválida (data_ocorrencia NULL) ficam fora.
CREATE OR REPLACE VIEW solides_bi.vw_ocorrencia_colaborador_mes AS
WITH parametro AS (SELECT DATE '2026-01-01' AS inicio_serie),
equipe AS (
    SELECT h.mes_ref, h.colaborador_id, h.colaborador_key
    FROM solides_bi.fato_headcount_mensal h
),
ocorrencia AS (
    SELECT date_trunc('month', o.data_ocorrencia)::date        AS mes_ref,
           o.colaborador_id,
           (array_agg(o.colaborador_key ORDER BY o.data_ocorrencia DESC, o.ocorrencia_id DESC))[1] AS colaborador_key,
           SUM(CASE WHEN t.grupo = 'Feedback'                THEN o.qtd ELSE 0 END) AS feedbacks,
           SUM(CASE WHEN t.tipo_feedback = 'Positivo'        THEN o.qtd ELSE 0 END) AS feedback_positivo,
           SUM(CASE WHEN t.tipo_feedback = 'Neutro'          THEN o.qtd ELSE 0 END) AS feedback_neutro,
           SUM(CASE WHEN t.tipo_feedback = 'Para melhorar'   THEN o.qtd ELSE 0 END) AS feedback_para_melhorar,
           SUM(CASE WHEN t.grupo = 'Medida disciplinar'      THEN o.qtd ELSE 0 END) AS medidas,
           SUM(CASE WHEN t.tipo_medida = 'Advertência'       THEN o.qtd ELSE 0 END) AS medida_advertencia,
           SUM(CASE WHEN t.tipo_medida = 'Suspensão'         THEN o.qtd ELSE 0 END) AS medida_suspensao,
           SUM(CASE WHEN t.tipo_medida = 'Outros'            THEN o.qtd ELSE 0 END) AS medida_outros,
           SUM(CASE WHEN t.grupo = 'Outros'                  THEN o.qtd ELSE 0 END) AS outras_ocorrencias
    FROM solides_bi.fato_ocorrencia o
    JOIN solides_bi.dim_tipo_ocorrencia t ON t.tipo_ocorrencia_key = o.tipo_ocorrencia_key
    CROSS JOIN parametro p
    WHERE o.data_valida
      AND o.data_ocorrencia >= p.inicio_serie
    GROUP BY 1, 2
),
uniao AS (
    SELECT COALESCE(e.mes_ref, oc.mes_ref)                     AS mes_ref,
           COALESCE(e.colaborador_id, oc.colaborador_id)       AS colaborador_id,
           COALESCE(e.colaborador_key, oc.colaborador_key)     AS colaborador_key,
           CASE WHEN e.colaborador_id IS NOT NULL THEN 1 ELSE 0 END AS na_equipe,
           COALESCE(oc.feedbacks, 0)                           AS feedbacks,
           COALESCE(oc.feedback_positivo, 0)                   AS feedback_positivo,
           COALESCE(oc.feedback_neutro, 0)                     AS feedback_neutro,
           COALESCE(oc.feedback_para_melhorar, 0)              AS feedback_para_melhorar,
           COALESCE(oc.medidas, 0)                             AS medidas,
           COALESCE(oc.medida_advertencia, 0)                  AS medida_advertencia,
           COALESCE(oc.medida_suspensao, 0)                    AS medida_suspensao,
           COALESCE(oc.medida_outros, 0)                       AS medida_outros,
           COALESCE(oc.outras_ocorrencias, 0)                  AS outras_ocorrencias
    FROM equipe e
    FULL JOIN ocorrencia oc ON oc.mes_ref = e.mes_ref AND oc.colaborador_id = e.colaborador_id
)
SELECT
    u.mes_ref,
    u.colaborador_id,
    d.empresa,
    d.area,
    COALESCE(d.gestor_id, -1)                                  AS gestor_id,
    COALESCE(d.gestor_nome, 'Sem gestor')                      AS gestor_nome,
    u.na_equipe,
    u.feedbacks,
    u.feedback_positivo,
    u.feedback_neutro,
    u.feedback_para_melhorar,
    CASE WHEN u.na_equipe = 1 AND u.feedbacks > 0 THEN 1 ELSE 0 END AS coberto,
    u.medidas,
    u.medida_advertencia,
    u.medida_suspensao,
    u.medida_outros,
    CASE WHEN u.medidas > 0 THEN 1 ELSE 0 END                  AS com_medida,
    CASE WHEN u.medidas > 1 THEN 1 ELSE 0 END                  AS reincidente_mes,
    u.outras_ocorrencias
FROM uniao u
JOIN solides_bi.dim_colaborador d ON d.colaborador_key = u.colaborador_key;


-- vw_avd: 1 linha por avaliação (última versão) dos ciclos de Desempenho trimestral. Bloco AVD.
-- Ciclo do período M = ciclo com vigente_de <= M <= vigente_ate (do mês de início até o mês anterior
-- ao início do ciclo seguinte; o último fica vigente até o mês corrente).
--   % concluídas (x/y)      = SUM(qtd_finalizada) / SUM(qtd_avaliacao) * 100, no ciclo do período
--   Finalizadas x Pendentes = SUM(qtd_finalizada), SUM(qtd_pendente)
--   vs ciclo anterior       = mesma conta com ciclo_key = ciclo_anterior_key
--   Conclusão por gestor    = GROUP BY avaliador_id, avaliador_nome (quem precisa responder)
-- empresa/area/gestor_id = do AVALIADO (para os filtros globais).
CREATE OR REPLACE VIEW solides_bi.vw_avd AS
WITH ciclo AS (
    SELECT c.ciclo_key, c.ciclo, c.status, c.data_inicio, c.data_fim, c.ano_trimestre_ref,
           ROW_NUMBER() OVER (ORDER BY c.data_inicio, c.ciclo_key)         AS ciclo_ordem,
           LAG(c.ciclo_key) OVER (ORDER BY c.data_inicio, c.ciclo_key)     AS ciclo_anterior_key,
           date_trunc('month', c.data_inicio)::date                        AS vigente_de,
           COALESCE((date_trunc('month', LEAD(c.data_inicio) OVER (ORDER BY c.data_inicio, c.ciclo_key))
                     - interval '1 month')::date,
                    date_trunc('month', DATE '2026-10-31')::date)               AS vigente_ate
    FROM solides_bi.dim_ciclo_avaliacao c
    WHERE c.tipo_ciclo = 'Desempenho trimestral'
)
SELECT
    ci.ciclo_key,
    ci.ciclo,
    ci.status                                                  AS ciclo_status,
    ci.ciclo_ordem,
    ci.ciclo_anterior_key,
    ci.data_inicio,
    ci.data_fim,
    ci.ano_trimestre_ref,
    ci.vigente_de,
    ci.vigente_ate,
    a.avaliacao_id,
    a.colaborador_id                                           AS avaliado_id,
    d.empresa,
    d.area,
    COALESCE(d.gestor_id, -1)                                  AS gestor_id,
    COALESCE(d.gestor_nome, 'Sem gestor')                      AS gestor_nome,
    COALESCE(av.colaborador_id, -1)                            AS avaliador_id,
    COALESCE(av.nome, 'Não identificado')                      AS avaliador_nome,
    a.data_avaliacao,
    1                                                          AS qtd_avaliacao,
    a.qtd_respondida                                           AS qtd_finalizada,
    1 - a.qtd_respondida                                       AS qtd_pendente
FROM solides_bi.fato_avaliacao a
JOIN ciclo ci ON ci.ciclo_key = a.ciclo_key
JOIN solides_bi.dim_colaborador d ON d.colaborador_key = a.colaborador_key
LEFT JOIN solides_bi.dim_colaborador av ON av.colaborador_key = a.gestor_key
WHERE a.qtd_avaliacao = 1;


-- vw_indicador_mensal: formato longo, 1 linha por mês x indicador x empresa x área x gestor.
-- Serve os 8 cards (mês e "comparar com"), a Evolução comparativa e o Painel de Atenção.
-- Construída sobre as vw_ acima (mesma regra, sem duplicar lógica).
--   Valor do card (unidade de meta_indicador):
--     '%'    -> SUM(numerador) / SUM(denominador) * 100      (absenteismo, hora_extra, feedback, avd_conclusao)
--     'h'    -> SUM(numerador) / SUM(denominador) / 60       (banco_horas = saldo médio; desde 09/2026)
--     'dias' -> SUM(numerador) / SUM(denominador)            (sla_vagas)
--     'qtd'  -> SUM(numerador)                               (medidas_disciplinares; turnover = desligamentos, meta do RH desde 26/10/2026)
--   Variação = valor(Período) - valor(Comparar com).
--   Área crítica (Painel) = GROUP BY area no mês e pega a pior razão SUM(numerador)/SUM(denominador)
--     segundo meta_indicador.sentido. Para 'qtd' o denominador é a equipe (taxa por colaborador),
--     para não punir áreas grandes. banco_horas: pior = maior |saldo médio|. sla_vagas: sem área.
--   sla_vagas tem empresa/area/gestor NULL: o backend não aplica os filtros de pessoa a ele.
--   avd_conclusao: o ciclo se repete em cada mês da sua vigência (não somar meses).
CREATE OR REPLACE VIEW solides_bi.vw_indicador_mensal AS
WITH base AS (
    SELECT mes_ref, 'turnover'::text AS indicador, empresa, area, gestor_id, gestor_nome,
           desligamentos::numeric AS numerador, hc_medio::numeric AS denominador
    FROM solides_bi.vw_turnover
    UNION ALL
    -- absenteísmo LÍQUIDO (respeita abonos do Sólides). Meta do RH = 3%, coerente com o líquido.
    -- O bruto (ausencia_min) continua em vw_ponto para o detalhamento.
    SELECT mes_ref, 'absenteismo', empresa, area, gestor_id, gestor_nome, ausencia_liquida_min, previsto_min
    FROM solides_bi.vw_ponto
    UNION ALL
    SELECT mes_ref, 'hora_extra', empresa, area, gestor_id, gestor_nome, he_min, horas_normais_min
    FROM solides_bi.vw_ponto
    UNION ALL
    SELECT mes_ref, 'banco_horas', empresa, area, gestor_id, gestor_nome, saldo_min, qtd_com_saldo
    FROM solides_bi.vw_banco_horas
    WHERE qtd_com_saldo = 1
    UNION ALL
    SELECT mes_fechamento, 'sla_vagas', NULL, NULL, NULL, NULL, sla_dias, qtd_fechada
    FROM solides_bi.vw_vaga
    WHERE qtd_fechada = 1 AND sla_dias IS NOT NULL
    UNION ALL
    -- feedback = COBERTURA (% da equipe que recebeu feedback no mês). Meta do RH = 95%.
    SELECT mes_ref, 'feedback', empresa, area, gestor_id, gestor_nome, coberto, na_equipe
    FROM solides_bi.vw_ocorrencia_colaborador_mes
    UNION ALL
    SELECT mes_ref, 'medidas_disciplinares', empresa, area, gestor_id, gestor_nome, medidas, na_equipe
    FROM solides_bi.vw_ocorrencia_colaborador_mes
    UNION ALL
    SELECT m::date, 'avd_conclusao', a.empresa, a.area, a.gestor_id, a.gestor_nome, a.qtd_finalizada, a.qtd_avaliacao
    FROM solides_bi.vw_avd a
    CROSS JOIN LATERAL generate_series(a.vigente_de, a.vigente_ate, interval '1 month') AS m
)
SELECT mes_ref, indicador, empresa, area, gestor_id, gestor_nome,
       SUM(numerador)   AS numerador,
       SUM(denominador) AS denominador
FROM base
GROUP BY mes_ref, indicador, empresa, area, gestor_id, gestor_nome;


-- vw_meta_mensal: 1 linha por mês (desde 01/2026 até o mês corrente) x indicador, com a meta vigente
-- (linha de maior vigencia_inicio <= mês). Linhas de meta dos gráficos e status do Painel.
CREATE OR REPLACE VIEW solides_bi.vw_meta_mensal AS
WITH mes AS (
    SELECT m::date AS mes_ref
    FROM generate_series(DATE '2026-01-01', date_trunc('month', DATE '2026-10-31')::date, interval '1 month') AS m
),
indicador AS (
    SELECT DISTINCT indicador FROM solides_bi.meta_indicador
)
SELECT
    m.mes_ref,
    i.indicador,
    v.nome,
    v.unidade,
    v.sentido,
    v.meta,
    v.limite_amarelo,
    v.limite_vermelho,
    v.vigencia_inicio
FROM mes m
CROSS JOIN indicador i
LEFT JOIN LATERAL (
    SELECT x.*
    FROM solides_bi.meta_indicador x
    WHERE x.indicador = i.indicador AND x.vigencia_inicio <= m.mes_ref
    ORDER BY x.vigencia_inicio DESC
    LIMIT 1
) v ON true;


-- vw_atualizacao: 1 linha por fonte, com a última data disponível. Rodapé "Dados atualizados até":
-- usar a linha 'Ponto' (fonte mais atrasada, D-1) ou MIN(dados_ate) das fontes exibidas na página.
CREATE OR REPLACE VIEW solides_bi.vw_atualizacao AS
SELECT 'Ponto'::text AS fonte, MAX(p.data_apuracao) AS dados_ate FROM solides.ponto_saldo_diario p
UNION ALL
SELECT 'Cadastro (Gestão)', MAX(h.data_referencia) FROM solides.colaborador_historico h
UNION ALL
SELECT 'Ocorrências', MAX(o.data_ocorrencia) FROM solides.ocorrencia o WHERE o.data_ocorrencia <= DATE '2026-10-31'
UNION ALL
SELECT 'Vagas', MAX((v.data_status AT TIME ZONE 'America/Sao_Paulo')::date) FROM solides.vaga v
UNION ALL
SELECT 'AVD', MAX(a.data_avaliacao) FROM solides.avaliacao a;


-- Leitura para o backend (usuário a definir pelo Otto):
-- GRANT USAGE ON SCHEMA solides_bi TO <usuario_dashboard>;
-- GRANT SELECT ON ALL TABLES IN SCHEMA solides_bi TO <usuario_dashboard>;


-- =====================================================================================
-- POWER BI: views simples que só repassam as views materializadas e a tabela de metas.
-- O navegador do Power BI (conector PostgreSQL) não lista views materializadas; estas aparecem.
-- Não copiam dado: leem direto das materializadas, então seguem atualizadas pelo atualizar().
-- Pedido do André em 26/10/2026. Importar no Power BI só as pbi_* (as vw_* são do painel web).
-- =====================================================================================
CREATE OR REPLACE VIEW solides_bi.pbi_dim_calendario        AS SELECT * FROM solides_bi.dim_calendario;
CREATE OR REPLACE VIEW solides_bi.pbi_dim_colaborador       AS SELECT * FROM solides_bi.dim_colaborador;
CREATE OR REPLACE VIEW solides_bi.pbi_dim_ciclo_avaliacao   AS SELECT * FROM solides_bi.dim_ciclo_avaliacao;
CREATE OR REPLACE VIEW solides_bi.pbi_dim_tipo_ocorrencia   AS SELECT * FROM solides_bi.dim_tipo_ocorrencia;
CREATE OR REPLACE VIEW solides_bi.pbi_fato_ponto_diario     AS SELECT * FROM solides_bi.fato_ponto_diario;
CREATE OR REPLACE VIEW solides_bi.pbi_fato_headcount_mensal AS SELECT * FROM solides_bi.fato_headcount_mensal;
CREATE OR REPLACE VIEW solides_bi.pbi_fato_movimentacao     AS SELECT * FROM solides_bi.fato_movimentacao;
CREATE OR REPLACE VIEW solides_bi.pbi_fato_vaga             AS SELECT * FROM solides_bi.fato_vaga;
CREATE OR REPLACE VIEW solides_bi.pbi_fato_ocorrencia       AS SELECT * FROM solides_bi.fato_ocorrencia;
CREATE OR REPLACE VIEW solides_bi.pbi_fato_avaliacao        AS SELECT * FROM solides_bi.fato_avaliacao;
CREATE OR REPLACE VIEW solides_bi.pbi_meta_indicador        AS SELECT * FROM solides_bi.meta_indicador;
