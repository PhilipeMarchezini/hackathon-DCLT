#!/bin/sh
set -eu
awslocal sqs create-queue --queue-name solidary-donations-dlq
DLQ_ARN="$(awslocal sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/solidary-donations-dlq --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
awslocal sqs create-queue --queue-name solidary-donations --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"}"
