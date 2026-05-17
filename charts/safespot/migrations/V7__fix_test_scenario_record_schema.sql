ALTER TABLE test_scenario_record
    ADD COLUMN IF NOT EXISTS record_id BIGSERIAL;

ALTER TABLE test_scenario_record
    ADD COLUMN IF NOT EXISTS scenario_name VARCHAR(200);

UPDATE test_scenario_record
SET scenario_name = scenario_id
WHERE scenario_name IS NULL;

ALTER TABLE test_scenario_record
    ALTER COLUMN scenario_name SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'pk_test_scenario_record'
    ) THEN
        ALTER TABLE test_scenario_record
            ADD CONSTRAINT pk_test_scenario_record PRIMARY KEY (record_id);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_test_scenario_record_scenario_id
    ON test_scenario_record (scenario_id);

CREATE INDEX IF NOT EXISTS idx_test_scenario_record_target
    ON test_scenario_record (target_table, target_id);
