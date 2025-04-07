CREATE OR REPLACE TABLE
  `sandboxportal.sandboxdataset.genai_food_labels` AS
SELECT
  *
FROM
  ML.GENERATE_TEXT(
    MODEL `sandboxportal.sandboxdataset.model_cloud_ai_gemini_pro`,
    (
      SELECT
        concat('generate nutrition label for ', products_brand_name) AS prompt
      FROM
        `sandboxportal.sandboxdataset.food_products`
      LIMIT
        100
    ),
    STRUCT(0.8 AS temperature, 3 AS top_k, TRUE AS flatten_json_output)
  );