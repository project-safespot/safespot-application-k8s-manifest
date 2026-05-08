UPDATE external_api_source
SET base_url = 'http://openapi.seoul.go.kr:8088/{KEY}/json/TbEqKkenvinfo/1/1000/',
    updated_at = NOW()
WHERE source_code = 'SEOUL_SHELTER_EARTHQUAKE';