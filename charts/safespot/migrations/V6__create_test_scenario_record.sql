CREATE TABLE IF NOT EXISTS test_scenario_record (
    scenario_id  VARCHAR(100) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    target_id    BIGINT       NOT NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_test_scenario_record_scenario_id
    ON test_scenario_record (scenario_id);

CREATE INDEX IF NOT EXISTS idx_test_scenario_record_target
    ON test_scenario_record (target_table, target_id);
