-- V5: align disaster_alert with normalization/read-model contract
-- - external-ingestion stores raw/canonical classification fields.
-- - async-worker read-model queries raw_type, message_category, level_rank, is_in_scope.
-- - level may be NULL when severity cannot be safely mapped.

ALTER TABLE disaster_alert
    ADD COLUMN IF NOT EXISTS raw_type VARCHAR(100),
    ADD COLUMN IF NOT EXISTS raw_category_tokens JSONB,
    ADD COLUMN IF NOT EXISTS message_category VARCHAR(20),
    ADD COLUMN IF NOT EXISTS raw_level VARCHAR(100),
    ADD COLUMN IF NOT EXISTS raw_level_tokens JSONB,
    ADD COLUMN IF NOT EXISTS level_rank SMALLINT,
    ADD COLUMN IF NOT EXISTS source_region VARCHAR(100),
    ADD COLUMN IF NOT EXISTS is_in_scope BOOLEAN,
    ADD COLUMN IF NOT EXISTS normalization_reason TEXT;

ALTER TABLE disaster_alert
    ALTER COLUMN level DROP NOT NULL;

ALTER TABLE disaster_alert
    DROP CONSTRAINT IF EXISTS disaster_alert_level_check;

ALTER TABLE disaster_alert
    ADD CONSTRAINT disaster_alert_level_check
    CHECK (
        level IS NULL
        OR level IN ('INTEREST', 'CAUTION', 'WARNING', 'CRITICAL')
    );

ALTER TABLE disaster_alert
    DROP CONSTRAINT IF EXISTS disaster_alert_message_category_check;

ALTER TABLE disaster_alert
    ADD CONSTRAINT disaster_alert_message_category_check
    CHECK (
        message_category IS NULL
        OR message_category IN ('ALERT', 'GUIDANCE', 'CLEAR')
    );

CREATE INDEX IF NOT EXISTS idx_alert_source_issued
    ON disaster_alert (source, issued_at);
