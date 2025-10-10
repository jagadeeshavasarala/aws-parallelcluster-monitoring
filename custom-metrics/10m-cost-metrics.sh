#!/bin/bash
set -x

# This script is intended to be run as a cron job every 10 minutes to collect and report cost metrics.

PROMETHEUS_URL="http://127.0.0.1:9091/metrics/job/cost"
CLUSTER_CONFIG_FILE="/opt/parallelcluster/shared/cluster-config.yaml"
REGION_NAME="US West (Oregon)"
REGION_CODE="us-west-2"
CRON_JOB_INTERVAL=10 # in minutes

if [[ ! -f "$CLUSTER_CONFIG_FILE" ]]; then
    echo "ERROR: Cluster config file not found at $CLUSTER_CONFIG_FILE"
    return 1
fi
cluster_name=$(yq -r '.Tags[] | select(.Key == "ClusterName") | .Value' "$CLUSTER_CONFIG_FILE")
if [[ -z "$cluster_name" ]]; then
    echo "ERROR: Could not extract cluster name from config file"
    return 1
fi

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
    volume_type="$1"
    pricing_data=$(aws pricing get-products \
        --service-code AmazonEC2 \
        --filters Type=TERM_MATCH,Field=location,Value="$REGION_NAME" \
                  Type=TERM_MATCH,Field=productFamily,Value=Storage \
                  Type=TERM_MATCH,Field=volumeApiName,Value="$volume_type" \
        --region us-east-1 \
        --query 'PriceList[0]' \
        --output text)
    monthly_price=$(echo "$pricing_data" | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD')
    hourly_price=$(echo "scale=5; $monthly_price / (24 * 30)" | bc -l)
    echo "$hourly_price"
}

EBS_PRICE=$(get_ebs_pricing "gp3")

send_metrics() {
    metrics="$1"

    if [[ -n "$metrics" ]]; then
		if printf "%s\n" "$metrics" | curl -s -X PUT "$PROMETHEUS_URL" \
            --data-binary @- \
            --connect-timeout 10 \
            --max-time 60; then
            return 0
        else
            echo "Failed to send metrics"
            return 1
        fi
    fi
}

collect_pcluster_metrics() {
    instances=$(aws ec2 describe-instances \
        --filters "Name=tag:Application,Values=dockyard-pcluster" \
                  "Name=tag:ClusterName,Values=$cluster_name" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags]' \
        --region "$REGION_CODE" \
        --output json)
    all_metrics=""
    for instance_data in $(echo "$instances" | jq -r '.[] | @base64'); do
        instance_data=$(echo "$instance_data" | base64 -d)
        instance_id=$(echo "$instance_data" | jq -r '.[0]')
        instance_type=$(echo "$instance_data" | jq -r '.[1]')
        tags=$(echo "$instance_data" | jq -r '.[2]')
        node_name=$(echo "$tags" | jq -r '.[] | select(.Key=="Name") | .Value')
        queue_name=$(echo "$tags" | jq -r '.[] | select(.Key=="parallelcluster:queue-name") | .Value')
        queue_name=${queue_name:-"HeadNode"}
        instance_price=$(get_instance_pricing "$instance_type")
        instance_cost=$(echo "scale=5; $instance_price * ($CRON_JOB_INTERVAL / 60)" | bc -l)
        labels="instance_type=\"$instance_type\",node_name=\"$node_name\",queue=\"$queue_name\",instance_id=\"$instance_id\""
        all_metrics="${all_metrics}pcluster_compute_cost{${labels}} ${instance_cost}"$'\n'
        volumes=$(aws ec2 describe-volumes \
            --filters "Name=attachment.instance-id,Values=$instance_id" \
            --query 'Volumes[].[VolumeId,VolumeType,Size]' \
            --region "$REGION_CODE" \
            --output json)
        volume_id=$(echo "$volumes" | jq -r '.[0][0]')
        volume_type=$(echo "$volumes" | jq -r '.[0][1]')
        volume_size=$(echo "$volumes" | jq -r '.[0][2]')
        storage_cost=$(echo "scale=5; $EBS_PRICE * $volume_size * ($CRON_JOB_INTERVAL / 60)" | bc -l)
        labels="${labels},volume_size=\"${volume_size}\",volume_type=\"${volume_type}\",volume_id=\"${volume_id}\""
        all_metrics="${all_metrics}pcluster_storage_cost{${labels}} ${storage_cost}"$'\n'
        total_cost=$(echo "scale=5; $instance_cost + $storage_cost" | bc -l)
        all_metrics="${all_metrics}pcluster_cost{${labels}} ${total_cost}"$'\n'
    done

    send_metrics "$all_metrics"
}

main() {
    collect_pcluster_metrics
}

main "$@"