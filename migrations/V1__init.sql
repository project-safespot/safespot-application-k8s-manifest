-- ============================================================
-- V1__init.sql
-- 재난대응 서비스 Aurora PostgreSQL DDL
-- 설계 문서: v10.0 기준
-- ============================================================

-- ============================================================
-- 1. app_user
-- ============================================================
CREATE TABLE app_user (
    user_id       BIGSERIAL    PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    name          VARCHAR(50)  NOT NULL,
    rrn_front_6   VARCHAR(255) NULL,
    phone         VARCHAR(20)  NULL,
    role          VARCHAR(10)  NOT NULL DEFAULT 'USER'
                      CHECK (role IN ('USER', 'ADMIN')),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX idx_user_username ON app_user (username);


-- ============================================================
-- 2. shelter
-- ============================================================
CREATE TABLE shelter (
    shelter_id     BIGSERIAL    PRIMARY KEY,
    name           VARCHAR(100) NOT NULL,
    shelter_type   VARCHAR(50)  NOT NULL,
    disaster_type  VARCHAR(20)  NOT NULL
                       CHECK (disaster_type IN ('EARTHQUAKE', 'LANDSLIDE', 'FLOOD')),
    address        VARCHAR(255) NOT NULL,
    latitude       DECIMAL(10,7) NOT NULL,
    longitude      DECIMAL(10,7) NOT NULL,
    capacity       INT          NOT NULL,
    manager        VARCHAR(50)  NULL,
    contact        VARCHAR(50)  NULL,
    shelter_status VARCHAR(20)  NOT NULL DEFAULT 'OPERATING'
                       CHECK (shelter_status IN ('OPERATING', 'STOPPED', 'PREPARING')),
    note           TEXT         NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_shelter_shelter_type  ON shelter (shelter_type);
CREATE INDEX idx_shelter_disaster_type ON shelter (disaster_type);
CREATE INDEX idx_shelter_status        ON shelter (shelter_status);
CREATE INDEX idx_shelter_location      ON shelter (latitude, longitude);


-- ============================================================
-- 3. disaster_alert
-- ============================================================
CREATE TABLE disaster_alert (
    alert_id      BIGSERIAL    PRIMARY KEY,
    disaster_type VARCHAR(20)  NOT NULL
                      CHECK (disaster_type IN ('EARTHQUAKE', 'LANDSLIDE', 'FLOOD')),
    region        VARCHAR(100) NOT NULL,
    level         VARCHAR(10)  NOT NULL
                      CHECK (level IN ('INTEREST', 'CAUTION', 'WARNING', 'CRITICAL')),
    message       TEXT         NOT NULL,
    source        VARCHAR(50)  NOT NULL,
    issued_at     TIMESTAMPTZ  NOT NULL,
    expired_at    TIMESTAMPTZ  NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_alert_region_type ON disaster_alert (region, disaster_type);
CREATE INDEX idx_alert_issued_at   ON disaster_alert (issued_at DESC);


-- ============================================================
-- 4. disaster_alert_detail
-- ============================================================
CREATE TABLE disaster_alert_detail (
    detail_id   BIGSERIAL    PRIMARY KEY,
    alert_id    BIGINT       NOT NULL UNIQUE
                    REFERENCES disaster_alert (alert_id) ON DELETE CASCADE,
    detail_type VARCHAR(30)  NOT NULL,
    magnitude   DECIMAL(4,1) NULL,
    epicenter   VARCHAR(255) NULL,
    intensity   VARCHAR(20)  NULL,
    detail_json JSONB        NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_alert_detail_type ON disaster_alert_detail (detail_type);


-- ============================================================
-- 5. evacuation_entry
-- ============================================================
CREATE TABLE evacuation_entry (
    entry_id      BIGSERIAL    PRIMARY KEY,
    shelter_id    BIGINT       NOT NULL
                      REFERENCES shelter (shelter_id) ON DELETE CASCADE,
    alert_id      BIGINT       NULL
                      REFERENCES disaster_alert (alert_id) ON DELETE SET NULL,
    user_id       BIGINT       NULL
                      REFERENCES app_user (user_id) ON DELETE SET NULL,
    visitor_name  VARCHAR(50)  NULL,
    visitor_phone VARCHAR(20)  NULL,
    address       VARCHAR(255) NULL,
    entry_status  VARCHAR(15)  NOT NULL DEFAULT 'ENTERED'
                      CHECK (entry_status IN ('ENTERED', 'EXITED', 'TRANSFERRED')),
    entered_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    exited_at     TIMESTAMPTZ  NULL,
    note          TEXT         NULL
);

CREATE INDEX idx_entry_shelter_status ON evacuation_entry (shelter_id, entry_status);
CREATE INDEX idx_entry_user           ON evacuation_entry (user_id);


-- ============================================================
-- 6. entry_detail
-- ============================================================
CREATE TABLE entry_detail (
    detail_id               BIGSERIAL    PRIMARY KEY,
    entry_id                BIGINT       NOT NULL UNIQUE
                                REFERENCES evacuation_entry (entry_id) ON DELETE CASCADE,
    family_info             TEXT         NULL,
    health_status           VARCHAR(200) NULL,
    health_note             TEXT         NULL,
    special_protection_flag BOOLEAN      NOT NULL DEFAULT FALSE,
    support_note            TEXT         NULL,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX idx_detail_entry_id          ON entry_detail (entry_id);
CREATE INDEX        idx_detail_special_protection ON entry_detail (special_protection_flag);


-- ============================================================
-- 7. evacuation_event_history
-- ============================================================
CREATE TABLE evacuation_event_history (
    history_id  BIGSERIAL   PRIMARY KEY,
    entry_id    BIGINT      NOT NULL
                    REFERENCES evacuation_entry (entry_id) ON DELETE CASCADE,
    shelter_id  BIGINT      NOT NULL
                    REFERENCES shelter (shelter_id) ON DELETE CASCADE,
    event_type  VARCHAR(20) NOT NULL
                    CHECK (event_type IN ('CHECK_IN', 'CHECK_OUT', 'TRANSFER', 'STATUS_UPDATE')),
    prev_status VARCHAR(30) NULL,
    next_status VARCHAR(30) NOT NULL,
    recorded_by BIGINT      NULL
                    REFERENCES app_user (user_id) ON DELETE SET NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    remark      TEXT        NULL
);

CREATE INDEX idx_history_recorded_at ON evacuation_event_history (recorded_at DESC);


-- ============================================================
-- 8. admin_audit_log
-- ============================================================
CREATE TABLE admin_audit_log (
    log_id         BIGSERIAL    PRIMARY KEY,
    admin_id       BIGINT       NOT NULL
                       REFERENCES app_user (user_id) ON DELETE RESTRICT,
    action         VARCHAR(100) NOT NULL,
    target_type    VARCHAR(50)  NULL,
    target_id      BIGINT       NULL,
    payload_before JSONB        NULL,
    payload_after  JSONB        NULL,
    ip_address     VARCHAR(45)  NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_audit_admin_created ON admin_audit_log (admin_id, created_at DESC);


-- ============================================================
-- 9. weather_log
-- ============================================================
CREATE TABLE weather_log (
    log_id      BIGSERIAL    PRIMARY KEY,
    nx          INT          NOT NULL,
    ny          INT          NOT NULL,
    base_date   DATE         NOT NULL,
    base_time   VARCHAR(4)   NOT NULL,
    forecast_dt TIMESTAMPTZ  NOT NULL,
    tmp         DECIMAL(4,1) NULL,
    sky         VARCHAR(10)  NULL,
    pty         VARCHAR(10)  NULL,
    pop         INT          NULL,
    pcp         VARCHAR(20)  NULL,
    wsd         DECIMAL(4,1) NULL,
    reh         INT          NULL,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (nx, ny, base_date, base_time, forecast_dt)
);

CREATE INDEX idx_weather_grid_dt ON weather_log (nx, ny, forecast_dt DESC);


-- ============================================================
-- 10. air_quality_log
-- ============================================================
CREATE TABLE air_quality_log (
    log_id       BIGSERIAL    PRIMARY KEY,
    station_name VARCHAR(50)  NOT NULL,
    measured_at  TIMESTAMPTZ  NOT NULL,
    pm10         INT          NULL,
    pm10_grade   VARCHAR(10)  NULL,
    pm25         INT          NULL,
    pm25_grade   VARCHAR(10)  NULL,
    o3           DECIMAL(4,3) NULL,
    o3_grade     VARCHAR(10)  NULL,
    khai_value   INT          NULL,
    khai_grade   VARCHAR(10)  NULL,
    collected_at TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (station_name, measured_at)
);

CREATE INDEX idx_air_station_measured ON air_quality_log (station_name, measured_at DESC);


-- ============================================================
-- 11. external_api_source
-- ============================================================
CREATE TABLE external_api_source (
    source_id   BIGSERIAL    PRIMARY KEY,
    source_code VARCHAR(50)  NOT NULL UNIQUE,
    source_name VARCHAR(100) NOT NULL,
    provider    VARCHAR(100) NOT NULL,
    category    VARCHAR(30)  NOT NULL
                    CHECK (category IN ('DISASTER', 'ENVIRONMENT', 'SHELTER')),
    auth_type   VARCHAR(30)  NOT NULL
                    CHECK (auth_type IN ('API_KEY', 'FILE', 'NONE')),
    base_url    TEXT         NULL,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ext_source_category ON external_api_source (category);

INSERT INTO external_api_source (source_code, source_name, provider, category, auth_type, is_active) VALUES
    ('SAFETY_DATA_ALERT',       '재난문자',               '행정안전부', 'DISASTER',    'API_KEY', TRUE),
    ('KMA_EARTHQUAKE',          '지진 정보',              '기상청',     'DISASTER',    'API_KEY', TRUE),
    ('SEOUL_EARTHQUAKE',        '서울시 지진 발생 현황',  '서울시',     'DISASTER',    'API_KEY', TRUE),
    ('FORESTRY_LANDSLIDE',      '산사태 위험 예측',       '산림청',     'DISASTER',    'API_KEY', FALSE),
    ('SEOUL_RIVER_LEVEL',       '하천 수위',              '서울시',     'DISASTER',    'API_KEY', TRUE),
    ('KMA_WEATHER',             '날씨 단기예보',           '기상청',     'ENVIRONMENT', 'API_KEY', TRUE),
    ('AIR_KOREA_AIR_QUALITY',   '대기질',                 '에어코리아', 'ENVIRONMENT', 'API_KEY', TRUE),
    ('SEOUL_SHELTER_EARTHQUAKE','서울시 지진옥외대피소',  '서울시',     'SHELTER',     'API_KEY', TRUE),
    ('SEOUL_SHELTER_LANDSLIDE', '서울시 산사태 대피소',   '서울시',     'SHELTER',     'API_KEY', TRUE),
    ('SEOUL_SHELTER_FLOOD',     '서울시 수해 대피소',     '서울시',     'SHELTER',     'FILE',    TRUE);


-- ============================================================
-- 12. external_api_schedule
-- ============================================================
CREATE TABLE external_api_schedule (
    schedule_id         BIGSERIAL    PRIMARY KEY,
    source_id           BIGINT       NOT NULL
                            REFERENCES external_api_source (source_id) ON DELETE RESTRICT,
    schedule_name       VARCHAR(100) NOT NULL,
    cron_expr           VARCHAR(100) NULL,
    timezone            VARCHAR(50)  NOT NULL DEFAULT 'Asia/Seoul',
    request_params_json JSONB        NULL,
    is_enabled          BOOLEAN      NOT NULL DEFAULT TRUE,
    next_scheduled_at   TIMESTAMPTZ  NULL,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ext_schedule_next_run ON external_api_schedule (next_scheduled_at, is_enabled);
CREATE INDEX idx_ext_schedule_source   ON external_api_schedule (source_id);


-- ============================================================
-- 13. external_api_execution_log
-- ============================================================
CREATE TABLE external_api_execution_log (
    execution_id        BIGSERIAL    PRIMARY KEY,
    schedule_id         BIGINT       NULL
                            REFERENCES external_api_schedule (schedule_id) ON DELETE RESTRICT,
    source_id           BIGINT       NOT NULL
                            REFERENCES external_api_source (source_id) ON DELETE RESTRICT,
    execution_status    VARCHAR(20)  NOT NULL
                            CHECK (execution_status IN ('RUNNING', 'SUCCESS', 'FAILED', 'PARTIAL_SUCCESS')),
    started_at          TIMESTAMPTZ  NOT NULL,
    ended_at            TIMESTAMPTZ  NULL,
    http_status         INT          NULL,
    retry_count         INT          NOT NULL DEFAULT 0,
    records_fetched     INT          NOT NULL DEFAULT 0,
    records_normalized  INT          NOT NULL DEFAULT 0,
    records_failed      INT          NOT NULL DEFAULT 0,
    error_code          VARCHAR(100) NULL,
    error_message       TEXT         NULL,
    trace_id            VARCHAR(100) NULL,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ext_exec_source_started ON external_api_execution_log (source_id, started_at DESC);
CREATE INDEX idx_ext_exec_status_started ON external_api_execution_log (execution_status, started_at DESC);


-- ============================================================
-- 14. external_api_raw_payload
-- ============================================================
CREATE TABLE external_api_raw_payload (
    raw_id               BIGSERIAL    PRIMARY KEY,
    execution_id         BIGINT       NOT NULL
                             REFERENCES external_api_execution_log (execution_id) ON DELETE CASCADE,
    source_id            BIGINT       NOT NULL
                             REFERENCES external_api_source (source_id) ON DELETE RESTRICT,
    request_url          TEXT         NULL,
    request_params_json  JSONB        NULL,
    response_body        JSONB        NOT NULL,
    response_meta_json   JSONB        NULL,
    payload_hash         VARCHAR(128) NULL,
    collected_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    retention_expires_at TIMESTAMPTZ  NULL
);

CREATE INDEX idx_ext_raw_source_collected ON external_api_raw_payload (source_id, collected_at DESC);
CREATE INDEX idx_ext_raw_payload_hash     ON external_api_raw_payload (payload_hash);


-- ============================================================
-- 15. external_api_normalization_error
-- ============================================================
CREATE TABLE external_api_normalization_error (
    error_id      BIGSERIAL    PRIMARY KEY,
    execution_id  BIGINT       NOT NULL
                      REFERENCES external_api_execution_log (execution_id) ON DELETE CASCADE,
    raw_id        BIGINT       NULL
                      REFERENCES external_api_raw_payload (raw_id) ON DELETE SET NULL,
    source_id     BIGINT       NOT NULL
                      REFERENCES external_api_source (source_id) ON DELETE RESTRICT,
    target_table  VARCHAR(100) NOT NULL,
    failed_field  VARCHAR(100) NULL,
    raw_fragment  JSONB        NULL,
    error_reason  TEXT         NOT NULL,
    resolved      BOOLEAN      NOT NULL DEFAULT FALSE,
    resolved_note TEXT         NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at   TIMESTAMPTZ  NULL
);

CREATE INDEX idx_ext_norm_err_source_created ON external_api_normalization_error (source_id, created_at DESC);
CREATE INDEX idx_ext_norm_err_resolved       ON external_api_normalization_error (resolved, created_at DESC);
