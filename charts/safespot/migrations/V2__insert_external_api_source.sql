-- Align external_api_source rows with official API contracts.
-- DataInitializer is INSERT-only; this migration owns all subsequent base_url corrections.
INSERT INTO external_api_source (source_code, source_name, provider, category, auth_type, base_url, is_active, created_at, updated_at)
VALUES
    ('SAFETY_DATA_ALERT',       '재난문자',              '행정안전부',  'DISASTER',    'API_KEY', 'https://www.safetydata.go.kr/V2/api/DSSP-IF-00247',                                            TRUE, NOW(), NOW()),
    ('KMA_EARTHQUAKE',          '지진 정보',             '기상청',     'DISASTER',    'API_KEY', 'https://apis.data.go.kr/1360000/EqkInfoService/getEqkMsg',                                     TRUE, NOW(), NOW()),
    ('SEOUL_EARTHQUAKE',        '서울시 지진 발생 현황',   '서울시',     'DISASTER',    'API_KEY', 'http://openapi.seoul.go.kr:8088/{KEY}/json/TbEqkKenvinfo/1/20/',                               TRUE, NOW(), NOW()),
    ('FORESTRY_LANDSLIDE',      '산사태 위험 예측',        '산림청',     'DISASTER',    'API_KEY', 'https://apis.data.go.kr/1400119/slfswarnApi/getSlfswarnDataList',                              TRUE, NOW(), NOW()),
    ('SEOUL_RIVER_LEVEL',       '하천 수위',              '서울시',     'DISASTER',    'API_KEY', 'http://openapi.seoul.go.kr:8088/{KEY}/json/ListRiverStageService/1/50/',                       TRUE, NOW(), NOW()),
    ('KMA_WEATHER',             '날씨 초단기실황',         '기상청',     'ENVIRONMENT', 'API_KEY', 'https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getUltraSrtNcst',                    TRUE, NOW(), NOW()),
    ('AIR_KOREA_AIR_QUALITY',   '대기질',                '에어코리아',  'ENVIRONMENT', 'API_KEY', 'https://apis.data.go.kr/B552584/ArpltnInforInqireSvc/getCtprvnRltmMesureDnsty',                TRUE, NOW(), NOW()),
    ('SEOUL_SHELTER_EARTHQUAKE','서울시 지진옥외대피소',    '서울시',     'SHELTER',     'API_KEY', 'http://openapi.seoul.go.kr:8088/{KEY}/json/TbEqKkenvinfo/1/1000/',                                   TRUE, NOW(), NOW()),
    ('SEOUL_SHELTER_LANDSLIDE', '서울시 산사태 대피소',    'odcloud',   'SHELTER',     'API_KEY', 'https://api.odcloud.kr/api/15118898/v1/uddi:19815091-0f2c-4d7a-a77f-96cec77038ad',             TRUE, NOW(), NOW()),
    ('SEOUL_SHELTER_FLOOD',     '서울시 수해 대피소',      '서울시',     'SHELTER',     'FILE',    NULL,                                                                                           FALSE, NOW(), NOW())
ON CONFLICT (source_code) DO UPDATE SET
    source_name = EXCLUDED.source_name,
    provider    = EXCLUDED.provider,
    auth_type   = EXCLUDED.auth_type,
    base_url    = EXCLUDED.base_url,
    is_active   = EXCLUDED.is_active,
    updated_at  = NOW();
