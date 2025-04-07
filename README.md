# Food Label Generation Project

This project demonstrates how to generate nutrition labels for food products using Google Cloud BigQuery and the Gemini Pro language model through BigQuery ML.

## Prerequisites

Before you begin, ensure you have the following:

1.  **Google Cloud Account:** You need an active Google Cloud account.
2.  **Google Cloud CLI (gcloud) Installed and Configured:** Make sure you have the `gcloud` command-line tool installed and configured to connect to your Google Cloud account. You can find installation instructions on the [official Google Cloud documentation](https://cloud.google.com/sdk/docs/install). Ensure you have initialized the CLI using `gcloud init`.
3.  **BigQuery Enabled:** The BigQuery API must be enabled in your Google Cloud project. You can enable it through the [Google Cloud Console](https://console.cloud.google.com/apis/library/bigquery.googleapis.com).
4.  **`bq` Command-Line Tool:** The `bq` command-line tool, which is part of the `gcloud` CLI, should be available in your system's PATH.
5.  **Vertex AI API Enabled:** The Vertex AI API needs to be enabled in your Google Cloud project. You can enable it through the [Google Cloud Console](https://console.cloud.google.com/apis/library/aiplatform.googleapis.com).
6.  **Google Cloud Project: `sandboxportal`:** This project is specifically configured to use the project ID `sandboxportal`. Ensure your `gcloud` CLI is configured to use this project. You can set the default project using `gcloud config set project sandboxportal`.
7.  **BigQuery Dataset: `sandboxdataset`:** A BigQuery dataset named `sandboxdataset` must exist within your `sandboxportal` project. You can create a dataset using the [Google Cloud Console](https://console.cloud.google.com/bigquery) or using the `bq` command:
    ```bash
    bq mk --dataset sandboxportal:sandboxdataset
    ```

## Running the Project

Follow these steps to run the food label generation project:

1.  **Load Food Product Data:**
    Navigate to the directory containing the project files in your terminal and run the `load_source.sh` script. This script will load the data from `food_products.csv` into a BigQuery table named `food_products` within your `sandboxdataset`.
    ```bash
    ./load_source.sh
    ```

2.  **Set Up the BigQuery ML Model (Gemini Pro):**
    Run the `setup_bqml_vertex.sh` script. This script likely contains the commands to create the BigQuery ML model that uses the Gemini Pro model from Vertex AI.
    ```bash
    ./setup_bqml_vertex.sh
    ```
    *(Note: The exact content of this script is not provided, but it should handle the creation of the `sandboxportal.sandboxdataset.model_cloud_ai_gemini_pro` model.)*

3.  **Generate Food Labels:**
    Execute the `run_genai_food_labels.sh` script. This script will run the SQL query defined in `genai_food_labels.sql`, which uses the Gemini Pro model to generate nutrition labels based on the data in your `food_products` table and stores the results in a new table called `genai_food_labels` within your `sandboxdataset`.
    ```bash
    ./run_genai_food_labels.sh
    ```

## Project Files

* **`food_products.csv`**: Contains the source data for food products (e.g., brand names).
* **`genai_food_labels.sql`**: The BigQuery SQL script that uses the `ML.GENERATE_TEXT` function with the Gemini Pro model to generate nutrition labels.
* **`LICENSE`**: Contains the licensing information for the project.
* **`load_source.sh`**: A shell script to load the `food_products.csv` file into the `food_products` BigQuery table.
* **`README.md`**: This file, providing instructions and prerequisites for the project.
* **`run_genai_food_labels.sh`**: A shell script to execute the `genai_food_labels.sql` script on BigQuery.
* **`setup_bqml_vertex.sh`**: A shell script to set up the BigQuery ML model that uses Vertex AI's Gemini Pro model.

## Running the Project

Follow these steps to run the food label generation project:

1.  **Ensure Prerequisites are Met:** Verify that you have completed all the prerequisites listed in the [Prerequisites](#prerequisites) section. This includes having a Google Cloud account, `gcloud` CLI configured, BigQuery and Vertex AI APIs enabled, the `sandboxportal` project set, and the `sandboxdataset` created.

2.  **Load Food Product Data:**
    Navigate to the directory containing the project files in your terminal and run the `load_source.sh` script. This will load the data from `food_products.csv` into the `food_products` table in your `sandboxdataset`.
    ```bash
    ./load_source.sh
    ```

3.  **Set Up the BigQuery ML Model (Gemini Pro):**
    Execute the `setup_bqml_vertex.sh` script. This script will create the BigQuery ML model (`sandboxportal.sandboxdataset.model_cloud_ai_gemini_pro`) that uses the Gemini Pro model from Vertex AI.
    ```bash
    ./setup_bqml_vertex.sh
    ```
    *(Note: Ensure the script content correctly sets up the model.)*

4.  **Execute the GenAI Query (Generate Food Labels):**
    Run the `run_genai_food_labels.sh` script. This script will execute the SQL query in `genai_food_labels.sql`, which uses the Gemini Pro model to generate nutrition labels based on the data in the `food_products` table. The results will be stored in the `genai_food_labels` table within your `sandboxdataset`.
    ```bash
    ./run_genai_food_labels.sh
    ```

5.  **Verify the Results:**
    After the `run_genai_food_labels.sh` script completes, you can verify the generated food labels by querying the `genai_food_labels` table in the [Google Cloud Console](https://console.cloud.google.com/bigquery) or using the `bq` command:
    ```bash
    bq query --nouse_legacy_sql 'SELECT * FROM `sandboxportal.sandboxdataset.genai_food_labels` LIMIT 10;'
    ```

By following these steps in order, you should be able to successfully execute the GenAI query and generate food labels for your products.