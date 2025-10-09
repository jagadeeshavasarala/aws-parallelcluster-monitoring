#!/bin/bash
set -euo pipefail

# This script is intended to be run as a cron job every 10 minutes to collect and report cost metrics.

PROMETHEUS_URL="http://127.0.0.1:9091/metrics/job/cost"
CLUSTER_CONFIG_FILE="/opt/parallelcluster/shared/cluster-config.yaml"
REGION_NAME="US West (Oregon)"
CRON_JOB_INTERVAL=10 # in minutes


get_cluster_name() {
    if [[ ! -f "$CLUSTER_CONFIG_FILE" ]]; then
        echo "ERROR: Cluster config file not found at $CLUSTER_CONFIG_FILE"
        return 1
    fi
    cluster_name=$(yq -r '.Tags[] | select(.Key == "ClusterName") | .Value' "$CLUSTER_CONFIG_FILE" || echo "")
    if [[ -z "$cluster_name" ]]; then
        echo "ERROR: Could not extract cluster name from config file"
        return 1
    fi
    echo "$cluster_name"
}

get_instance_pricing() {
    instance_type="$1"
    pricing_data=$(aws pricing get-products \
        --service-code AmazonEC2 \
        --filters Type=TERM_MATCH,Field=instanceType,Value="$instance_type" \
                  Type=TERM_MATCH,Field=location,Value="$REGION_NAME" \
                  Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
                  Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
                  Type=TERM_MATCH,Field=tenancy,Value=Shared \
                  Type=TERM_MATCH,Field=capacitystatus,Value=UnusedCapacityReservation \
        --region us-east-1 \
        --query 'PriceList[0]' \
        --output text)
    hourly_price=$(echo "$pricing_data" | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD')
    echo "$hourly_price"
}

get_ebs_pricing() {
    # per GB per hour
    volume_type="$1"
    pricing_data=$(aws pricing get-products \
        --service-code AmazonEC2 \
        --filters Type=TERM_MATCH,Field=location,Value="$REGION_NAME" \
                  Type=TERM_MATCH,Field=productFamily,Value=Storage \
                  Type=TERM_MATCH,Field=volumeApiName,Value="$volume_type" \
        --region us-east-1 \
        --query 'PriceList[0]' \
        --output text)
    hourly_price=$(echo "$pricing_data" | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD')
    echo "$hourly_price"
}

EBS_PRICE=$(get_ebs_pricing "gp3")

send_metrics() {
    metrics="$1"

    if [[ -n "$metrics" ]]; then
        if printf "$metrics" | curl -s -X POST "$PROMETHEUS_URL" \
            --data-binary @- \
            --connect-timeout 10 \
            --max-time 10; then
            return 0
        else
            echo "Failed to send metrics"
            return 1
        fi
    fi
}

collect_pcluster_metrics() {
    cluster_name=$(get_cluster_name)
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to get cluster name"
        return 1
    fi
    instances=$(aws ec2 describe-instances \
        --filters "Name=tag:Application,Values=dockyard-pcluster" \
                  "Name=tag:ClusterName,Values=$cluster_name" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags]' \
        --output json)
    all_metrics=""
    echo "$instances" | jq -r '.[] | @base64' | while read -r instance_data; do
        instance_data=$(echo "$instance_data" | base64 -d)
        instance_id=$(echo "$instance_data" | jq -r '.[0]')
        instance_type=$(echo "$instance_data" | jq -r '.[1]')
        tags=$(echo "$instance_data" | jq -r '.[2]')
        node_name=$(echo "$tags" | jq -r '.[] | select(.Key=="Name") | .Value')
        queue_name=$(echo "$tags" | jq -r '.[] | select(.Key=="parallelcluster:queue-name") | .Value' || echo "")
        instance_price=$(get_instance_pricing "$instance_type")
        instance_cost=$(echo "scale=5; $instance_price * ($CRON_JOB_INTERVAL / 60)" | bc -l)
        labels="instance_type=\"$instance_type\",node_name=\"$node_name\",queue=\"$queue_name\",instance_id=\"$instance_id\""
        all_metrics="${all_metrics}pcluster_node_cost{${labels}} ${instance_cost}\n"
        total_storage_cost="0"
        total_volume_size="0"
        volumes=$(aws ec2 describe-volumes \
            --filters "Name=attachment.instance-id,Values=$instance_id" \
            --query 'Volumes[].[VolumeId,VolumeType,Size]' \
            --output json)
        if [[ -n "$volumes" && "$volumes" != "[]" ]]; then
            for volume_data in $(echo "$volumes" | jq -r '.[] | @base64'); do
                volume_data=$(echo "$volume_data" | base64 -d)
                volume_id=$(echo "$volume_data" | jq -r '.[0]')
                volume_type=$(echo "$volume_data" | jq -r '.[1]')
                volume_size=$(echo "$volume_data" | jq -r '.[2]')
                volume_cost=$(echo "scale=5; $EBS_PRICE * $volume_size * ($CRON_JOB_INTERVAL / 60)" | bc -l)
                total_storage_cost=$(echo "scale=5; $total_storage_cost + $volume_cost" | bc -l)
                total_volume_size=$(echo "scale=5; $total_volume_size + $volume_size" | bc -l)
            done
            storage_labels="${labels},volume_size=\"${total_volume_size}\",volume_type=\"${volume_type}\",volume_id=\"${volume_id}\""
            all_metrics="${all_metrics}pcluster_storage_cost{${storage_labels}} ${total_storage_cost}\n"
        fi
    done
    send_metrics "$all_metrics"
}

main() {
    collect_pcluster_metrics
}

main "$@"