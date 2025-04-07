
SELECT *
FROM
ML.GENERATE_TEXT(
 MODEL `sandboxportal.sandboxdataset.model_cloud_ai_gemini_pro`,
 (
  select concat ('generate nutrition label for ', products_brand_name) as prompt FROM `bigquery-public-data.fda_food.food_events` LIMIT 10000
 ),
 STRUCT(0.8 AS temperature, 3 AS top_k, TRUE AS flatten_json_output));

-- SELECT distinct products_brand_name FROM `bigquery-public-data.fda_food.food_events` LIMIT 10000
