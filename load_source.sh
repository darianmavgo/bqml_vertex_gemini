#!/bin/bash

# Load the food_products.csv file into the food_products table in BigQuery

bq load \
    --project_id=sandboxportal \
    --source_format=CSV \
    --autodetect \
    sandboxdataset.food_products \
    food_products.csv