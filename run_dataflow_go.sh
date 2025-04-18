#!/bin/bash
# export GOOGLE_APPLICATION_CREDENTIALS=credentials.json
# Replace with your project ID, region, and other relevant settings
PROJECT_ID="sandboxportal"
REGION="us-central1"
BUCKET_NAME="portalbucketsandbox"
TEMP_LOCATION="gs://sandboxportal/temp"
STAGING_LOCATION="gs://sandboxportal/staging"
MODEL_NAME="diabetes_model"

go run dataflow.go \
--project $PROJECT_ID \
--temp_location gs://$BUCKET_NAME/temp \
--staging_location gs://$BUCKET_NAME/staging \
--region $REGION \
--runner direct \


# go run dataflow.go \
#     --runner dataflow \
#     --region $REGION \
#     --staging_location gs://$BUCKET_NAME/binaries/

# # Build the Go executable
# go build -o dataflow_job

# # Run the Dataflow job
# gcloud dataflow jobs run \
#   --project=$PROJECT_ID \
#   --region=$REGION \
#   --gcs-location=$TEMP_LOCATION \
#   --staging-location=$STAGING_LOCATION \
#   --worker-machine-type=n1-standard-2 \
#   --max-workers=10 \
#   ./dataflow_job

#   (myenv) darhickman@penguin:~/development/Gitlab/dexcomita/bigquery/compare_bqml_vs_dataflow$ gcloud dataflow jobs run 
# ERROR: (gcloud.dataflow.jobs.run) argument JOB_NAME --gcs-location: Must be specified.
# Usage: gcloud dataflow jobs run JOB_NAME --gcs-location=GCS_LOCATION [optional flags]
#   optional flags may be  --additional-experiments | --dataflow-kms-key |
#                          --disable-public-ips | --enable-streaming-engine |
#                          --help | --max-workers | --network | --num-workers |
#                          --parameters | --region | --service-account-email |
#                          --staging-location | --subnetwork |
#                          --worker-machine-type | --worker-region |
#                          --worker-zone | --zone