#!/bin/sh
set -eu
until aws dynamodb list-tables --endpoint-url http://dynamodb:8000 --region us-east-1 >/dev/null 2>&1; do sleep 2; done
aws dynamodb create-table \
  --table-name SolidaryTechVolunteers \
  --attribute-definitions AttributeName=volunteer_id,AttributeType=S AttributeName=ngo_id,AttributeType=N \
  --key-schema AttributeName=volunteer_id,KeyType=HASH \
  --global-secondary-indexes 'IndexName=ngo_id-index,KeySchema=[{AttributeName=ngo_id,KeyType=HASH}],Projection={ProjectionType=ALL}' \
  --billing-mode PAY_PER_REQUEST \
  --endpoint-url http://dynamodb:8000 \
  --region us-east-1 || true
