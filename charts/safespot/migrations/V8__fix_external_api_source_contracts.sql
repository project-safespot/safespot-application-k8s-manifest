-- Fix external_api_source endpoint drift after V2/V3.
-- V3 pointed SEOUL_SHELTER_EARTHQUAKE at the Seoul earthquake occurrence API
-- (TbEqKkenvinfo). The shelter source must call the Seoul earthquake outdoor
-- shelter API (TlEtqkP).

UPDATE external_api_source
SET source_name = '서울시 지진옥외대피소',
    provider    = '서울시',
    auth_type   = 'API_KEY',
    base_url    = 'http://openapi.seoul.go.kr:8088/{KEY}/json/TlEtqkP/1/1000/',
    is_active   = TRUE,
    updated_at  = NOW()
WHERE source_code = 'SEOUL_SHELTER_EARTHQUAKE';

-- Align to the official 산림청 산사태 예측정보 endpoint.
UPDATE external_api_source
SET source_name = '산사태 위험 예측',
    provider    = '산림청',
    auth_type   = 'API_KEY',
    base_url    = 'http://apis.data.go.kr/1400000/predictionInfoService/predictionInfoList',
    is_active   = TRUE,
    updated_at  = NOW()
WHERE source_code = 'FORESTRY_LANDSLIDE';
