-- =====================================================================================
-- 01_schema_solides.sql
-- Estrutura completa do schema `solides` (Sólides Ponto/Tangerino + Sólides Gestão + AVD V3)
-- Idêntica ao modelo de produção (16 tabelas brutas), pronta para carga de dados fictícios do Case RH.
-- =====================================================================================

DROP SCHEMA IF EXISTS solides CASCADE;
CREATE SCHEMA solides;

-- ============================== 1. PONTO / DP (Tangerino) ==============================

CREATE TABLE solides.empresa (
    id              integer PRIMARY KEY,
    cnpj            varchar(255),
    codigo_externo  varchar(255),
    razao_social    varchar(255),
    nome_fantasia   varchar(255),
    nome_exibicao   varchar(255)
);

CREATE TABLE solides.setor (
    id     integer PRIMARY KEY,
    nome   varchar(255),
    ativo  boolean NOT NULL DEFAULT true
);

CREATE TABLE solides.regra_escala (
    id                                integer PRIMARY KEY,
    nome                              varchar(255),
    padrao                            boolean NOT NULL DEFAULT false,
    data_alteracao                    timestamptz,
    intervalo_pre_atribuido           boolean NOT NULL DEFAULT false,
    exibir_intrajornada_espelho_ponto boolean NOT NULL DEFAULT false,
    ignorar_feriado                   boolean NOT NULL DEFAULT false,
    inativo                           boolean NOT NULL DEFAULT false
);

CREATE TABLE solides.regra_ponto (
    id                                    integer PRIMARY KEY,
    descricao                             varchar(255),
    data_cadastro                         date,
    padrao                                boolean NOT NULL DEFAULT false,
    tipo_controle_saldo_horas             varchar(255),
    tipo_controle_jornada                 varchar(255),
    falta_debita_banco_horas              boolean NOT NULL DEFAULT false,
    domingo_banco_horas_como_hora_extra   boolean NOT NULL DEFAULT false,
    feriado_banco_horas_como_hora_extra   boolean NOT NULL DEFAULT false,
    limite_banco_horas_mes_min            integer DEFAULT 0
);

CREATE TABLE solides.feriado (
    id            integer PRIMARY KEY,
    ano           integer,
    descricao     varchar(255),
    data_feriado  date
);

CREATE TABLE solides.cargo (
    id              integer PRIMARY KEY,
    nome            varchar(255),
    cbo_id          integer,
    cbo             varchar(255),
    data_alteracao  timestamptz
);

CREATE TABLE solides.funcionario (
    id                  integer PRIMARY KEY,
    nome                varchar(255),
    nome_social         varchar(255),
    email               varchar(255),
    cpf                 varchar(255),
    genero              varchar(255),
    data_nascimento     date,
    empresa_id          integer REFERENCES solides.empresa(id),
    setor_id            integer REFERENCES solides.setor(id),
    ultimo_gestor_id    integer,
    data_admissao       date,
    data_efetivacao     date,
    data_demissao       date,
    demitido            boolean NOT NULL DEFAULT false,
    motivo_demissao     varchar(255),
    status              integer NOT NULL DEFAULT 0,
    registra_ponto      boolean NOT NULL DEFAULT false,
    cargo_id            integer REFERENCES solides.cargo(id),
    escala_trabalho_id  integer REFERENCES solides.regra_escala(id),
    duplo_vinculo       boolean NOT NULL DEFAULT false,
    centro_custo        varchar(255)
);

CREATE TABLE solides.lider (
    id              integer PRIMARY KEY,
    funcionario_id  integer REFERENCES solides.funcionario(id),
    demitido        boolean NOT NULL DEFAULT false,
    status          integer NOT NULL DEFAULT 0,
    duplo_vinculo   boolean NOT NULL DEFAULT false,
    registra_ponto  boolean NOT NULL DEFAULT false
);

CREATE TABLE solides.ponto_consolidado_diario (
    id                         bigint PRIMARY KEY,
    empresa_id                 integer,
    funcionario_id             integer REFERENCES solides.funcionario(id),
    escala_trabalho_id         integer REFERENCES solides.regra_escala(id),
    regra_ponto_id             integer REFERENCES solides.regra_ponto(id),
    data_apuracao              date,
    horas_trabalhadas_min      integer DEFAULT 0,
    horas_previstas_min        integer DEFAULT 0,
    saldo_horas_min            integer DEFAULT 0,
    saldo_horas_calculado_min  integer DEFAULT 0,
    saldo_banco_horas_min      integer DEFAULT 0,
    saldo_banco_excedente_min  integer DEFAULT 0,
    faltou                     boolean NOT NULL DEFAULT false,
    tempo_falta_min            integer DEFAULT 0,
    horas_restantes_min        integer DEFAULT 0,
    is_ajuste                  boolean NOT NULL DEFAULT false,
    horas_noturnas_min         integer DEFAULT 0,
    hora_extra_50_min          integer DEFAULT 0,
    hora_extra_100_min         integer DEFAULT 0,
    hora_extra_tipo3_min       integer DEFAULT 0,
    hora_extra_tipo4_min       integer DEFAULT 0,
    horas_pagas_min            integer DEFAULT 0,
    is_feriado                 boolean NOT NULL DEFAULT false,
    sobreaviso_horas_min       integer DEFAULT 0,
    sobreaviso_trabalhado_min  integer DEFAULT 0,
    hora_ficta_noturna_min     integer DEFAULT 0,
    tipo_movimentacao          varchar(255)
);

CREATE TABLE solides.ponto_saldo_diario (
    funcionario_id                   integer NOT NULL REFERENCES solides.funcionario(id),
    data_apuracao                    date    NOT NULL,
    horas_previstas_min              integer DEFAULT 0,
    horas_trabalhadas_min            integer DEFAULT 0,
    saldo_horas_min                  integer DEFAULT 0,
    saldo_banco_horas_acumulado_min  integer DEFAULT 0,
    data_inicio_banco_horas          date,
    CONSTRAINT ponto_saldo_diario_pkey PRIMARY KEY (funcionario_id, data_apuracao)
);

-- ============================== 2. GESTÃO ==============================

CREATE TABLE solides.departamento (
    id    integer PRIMARY KEY,
    nome  varchar(255)
);

CREATE TABLE solides.colaborador (
    id                integer PRIMARY KEY,
    nome              varchar(255),
    cpf               varchar(255),
    email             varchar(255),
    matricula         varchar(255),
    data_nascimento   date,
    genero            varchar(255),
    etnia             varchar(255),
    escolaridade      varchar(255),
    curso             varchar(255),
    tipo_contrato     varchar(255),
    turno             varchar(255),
    ativo             boolean NOT NULL DEFAULT false,
    data_admissao     date,
    data_demissao     date,
    motivo_demissao   varchar(255),
    gestor_id         integer REFERENCES solides.colaborador(id),
    departamento_id   integer REFERENCES solides.departamento(id),
    cargo_nome        varchar(255),
    unidade_id        integer,
    unidade_nome      varchar(255),
    data_atualizacao  date,
    origem            varchar(255) NOT NULL DEFAULT 'lista'
);

CREATE TABLE solides.colaborador_historico (
    colaborador_id   integer NOT NULL REFERENCES solides.colaborador(id),
    data_referencia  date    NOT NULL,
    ativo            boolean NOT NULL DEFAULT false,
    data_demissao    date,
    gestor_id        integer,
    departamento_id  integer,
    cargo_nome       varchar(255),
    unidade_id       integer,
    CONSTRAINT colaborador_historico_pkey PRIMARY KEY (colaborador_id, data_referencia)
);

CREATE TABLE solides.vaga (
    id                     integer PRIMARY KEY,
    titulo                 varchar(255),
    cargo                  varchar(255),
    tipo                   varchar(255),
    publico_alvo           varchar(255),
    nivel_hierarquico      varchar(255),
    status                 varchar(255),
    data_abertura          date,
    data_prazo             date,
    data_status            timestamptz,
    ativa                  boolean NOT NULL DEFAULT false,
    qtd_posicoes           integer DEFAULT 0,
    qtd_posicoes_ocupadas  integer DEFAULT 0,
    salario_minimo         decimal(12,2),
    salario_maximo         decimal(12,2),
    local                  varchar(255),
    cidade                 varchar(255),
    uf                     varchar(255),
    codigo_externo         varchar(255)
);

CREATE TABLE solides.ocorrencia (
    id                    integer PRIMARY KEY,
    colaborador_id        integer REFERENCES solides.colaborador(id),
    tipo                  varchar(255),
    classificacao         varchar(255),
    data_ocorrencia       date,
    data_ocorrencia_texto varchar(255),
    valor                 decimal(12,2) DEFAULT 0
);

-- ============================== 3. AVALIAÇÃO DE DESEMPENHO (V3) ==============================

CREATE TABLE solides.avaliacao_ciclo (
    id           integer PRIMARY KEY,
    nome         varchar(255),
    descricao    text,
    data_inicio  date,
    data_fim     date,
    status       varchar(255)
);

CREATE TABLE solides.avaliacao (
    avaliacao_ciclo_id     integer NOT NULL REFERENCES solides.avaliacao_ciclo(id),
    avaliador_id           integer NOT NULL REFERENCES solides.colaborador(id),
    avaliado_id            integer NOT NULL REFERENCES solides.colaborador(id),
    versao                 integer NOT NULL DEFAULT 1,
    data_avaliacao         date,
    cargo_avaliado         varchar(255),
    departamento_avaliado  varchar(255),
    perfil_avaliado        varchar(255),
    respondida             boolean NOT NULL DEFAULT false,
    qtd_criterios          integer NOT NULL DEFAULT 0,
    CONSTRAINT avaliacao_pkey PRIMARY KEY (avaliacao_ciclo_id, avaliador_id, avaliado_id, versao)
);

CREATE TABLE solides.avaliacao_criterio (
    avaliacao_ciclo_id  integer NOT NULL,
    avaliador_id        integer NOT NULL,
    avaliado_id         integer NOT NULL,
    versao              integer NOT NULL DEFAULT 1,
    criterio_id         integer NOT NULL,
    criterio_tipo       varchar(255),
    criterio_descricao  varchar(255),
    nota                decimal(5,2),
    peso                decimal(8,2),
    CONSTRAINT avaliacao_criterio_pkey PRIMARY KEY (avaliacao_ciclo_id, avaliador_id, avaliado_id, versao, criterio_id),
    CONSTRAINT avaliacao_criterio_avaliacao_foreign FOREIGN KEY (avaliacao_ciclo_id, avaliador_id, avaliado_id, versao)
        REFERENCES solides.avaliacao (avaliacao_ciclo_id, avaliador_id, avaliado_id, versao)
);
