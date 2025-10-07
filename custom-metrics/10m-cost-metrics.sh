#!/bin/bash
set -e
# This script is intended to be run as a cron job every 10 minutes to collect and report cost metrics.

PROMETHEUS_URL="http://127.0.0.1:9091/metrics/job/cost"
REGION_NAME="US West (Oregon)"
CLUSTER_CONFIG_FILE="/opt/parallelcluster/shared/cluster-config.yaml"
LOG_FILE="/tmp/cost-metrics.log"
COMPUTE_VOLUME_SIZE=50

touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

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
        --output text 2>/dev/null)

    price=$(echo "$pricing_data" | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD' 2>/dev/null)

    if [[ "$price" != "null" && "$price" != "" ]]; then
        echo "$price"
    else
        echo "ERROR: Failed to parse pricing for $instance_type" >&2
        echo "0.0"
    fi
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
        --output text 2>/dev/null)

    if [[ -z "$pricing_data" || "$pricing_data" == "None" ]]; then
        echo "ERROR: No EBS pricing data found for $volume_type" >&2
        echo "0.0"
        return
    fi

    price=$(echo "$pricing_data" | jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD' 2>/dev/null)

    if [[ "$price" != "null" && "$price" != "" ]]; then
        echo "$price"
    else
        echo "ERROR: Failed to parse EBS pricing for $volume_type" >&2
        echo "0.0"
    fi
}

EBS_VOLUME_PRICE=$(get_ebs_pricing "gp3")

send_metric() {
    name="$1"
    value="$2"
    if printf "%s %s\n" "$name" "$value" | curl -s -X POST "$PROMETHEUS_URL" \
        --data-binary @- \
        --connect-timeout 10 \
        --max-time 10 >/dev/null 2>&1; then
        echo "Successfully sent metric $name"
    else
        echo "ERROR: Failed to send metric $name" >&2
    fi
}

collect_master_metrics() {
    instance_type=$(yq '.HeadNode.InstanceType' "$CLUSTER_CONFIG_FILE" 2>/dev/null || echo "t3.small")
    vol_size=$(yq '.HeadNode.LocalStorage.RootVolume.Size' "$CLUSTER_CONFIG_FILE" 2>/dev/null || echo "50")

    master_price=$(get_instance_pricing "$instance_type")
    send_metric "master_node_cost" "$master_price"

    ebs_cost=$(echo "scale=10; $EBS_VOLUME_PRICE * $vol_size / 720" | bc -l || echo "0")
    send_metric "ebs_master_cost" "$ebs_cost"

}

collect_compute_metrics() {
    total_compute_cost=0
    total_ebs_cost=0
    queues=$(yq '.SlurmQueues[].Name' "$CLUSTER_CONFIG_FILE" 2>/dev/null || echo "")

    if [[ -z "$queues" ]]; then
        echo "No queues found in cluster configuration"
        send_metric "compute_nodes_cost" "0"
        send_metric "ebs_compute_cost" "0"
        return
    fi

    for queue_name in $queues; do
        instance_type=$(yq '.SlurmQueues[] | select(.Name == "'"$queue_name"'") | .ComputeResources[0].InstanceType' "$CLUSTER_CONFIG_FILE" 2>/dev/null)

        if [[ -n "$instance_type" ]]; then
            total_nodes=0
            if command -v /opt/slurm/bin/sinfo >/dev/null 2>&1; then
                sinfo_output=$(/opt/slurm/bin/sinfo --noheader --partition "$queue_name" --format "%t %D" 2>/dev/null || echo "")
                if [[ -n "$sinfo_output" ]]; then
                    while IFS= read -r line; do
                        state=$(echo "$line" | awk '{print $1}')
                        nodes=$(echo "$line" | awk '{print $2}')
                        if [[ -n "$line" && "$state" != "idle~" && "$nodes" =~ ^[0-9]+$ ]]; then
                            total_nodes=$((total_nodes + nodes))
                        fi
                    done <<< "$sinfo_output"
                fi
            fi

            if [[ $total_nodes -gt 0 ]]; then
                instance_price=$(get_instance_pricing "$instance_type")
                compute_cost=$(echo "scale=10; $instance_price * $total_nodes" | bc -l || echo "0")
                total_compute_cost=$(echo "scale=10; $total_compute_cost + $compute_cost" | bc -l || echo "$total_compute_cost")

                ebs_cost=$(echo "scale=10; $EBS_VOLUME_PRICE * $total_nodes * COMPUTE_VOLUME_SIZE / 720" | bc -l || echo "0")
                total_ebs_cost=$(echo "scale=10; $total_ebs_cost + $ebs_cost" | bc -l || echo "$total_ebs_cost")
            fi
        else
            echo "No instance type found for queue: $queue_name"
        fi
    done

    send_metric "compute_nodes_cost" "$total_compute_cost"
    send_metric "ebs_compute_cost" "$total_ebs_cost"
}

main() {
    collect_master_metrics
    collect_compute_metrics
}

main "$@"