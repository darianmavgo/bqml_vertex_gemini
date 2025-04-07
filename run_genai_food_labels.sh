#!/bin/bash

# Run the genai_food_labels.sql script against BigQuery

bq query \
    --project_id=sandboxportal \
    --use_legacy_sql=false \
    --nouse_cache \
    --script=genai_food_labels.sql