#!/usr/bin/env python3
"""
AWS ParallelCluster Cost Monitoring Script
"""
import json
import subprocess
import requests
import boto3
import diskcache
import yaml
from ec2_metadata import ec2_metadata

CACHE = diskcache.Cache('/tmp/cost-metrics-cache', size_limit=100e6)
CACHE_TTL = 7 * 24 * 3600  # 7 days
PROMETHEUS_URL = 'http://127.0.0.1:9091/metrics/job/cost'
REGION_NAME = 'US West (Oregon)'

ec2 = boto3.client('ec2')
pricing = boto3.client('pricing', region_name='us-east-1')

cluster_config_file = "/opt/parallelcluster/shared/cluster-config.yaml"
config = yaml.safe_load(open(cluster_config_file))


@CACHE.memoize(expire=CACHE_TTL)
def get_instance_pricing(instance_type, region_name):
    try:
        response = pricing.get_products(
            ServiceCode='AmazonEC2',
            Filters=[
                {'Type': 'TERM_MATCH', 'Field': 'instanceType', 'Value': instance_type},
                {'Type': 'TERM_MATCH', 'Field': 'location', 'Value': region_name},
                {'Type': 'TERM_MATCH', 'Field': 'preInstalledSw', 'Value': 'NA'},
                {'Type': 'TERM_MATCH', 'Field': 'operatingSystem', 'Value': 'Linux'},
                {'Type': 'TERM_MATCH', 'Field': 'tenancy', 'Value': 'Shared'},
                {'Type': 'TERM_MATCH', 'Field': 'capacitystatus', 'Value': 'UnusedCapacityReservation'}
            ]
        )
        price_list = json.loads(response['PriceList'][0])
        price = float(price_list['terms']['OnDemand'][list(price_list['terms']['OnDemand'].keys())[0]]
                     ['priceDimensions'][list(price_list['terms']['OnDemand'][list(price_list['terms']['OnDemand'].keys())[0]]['priceDimensions'].keys())[0]]
                     ['pricePerUnit']['USD'])
        return price
    except:
        return 0.0


@CACHE.memoize(expire=CACHE_TTL)
def get_ebs_pricing(volume_type, region_name):
    try:
        response = pricing.get_products(
            ServiceCode='AmazonEC2',
            Filters=[
                {'Type': 'TERM_MATCH', 'Field': 'location', 'Value': region_name},
                {'Type': 'TERM_MATCH', 'Field': 'productFamily', 'Value': 'Storage'},
                {'Type': 'TERM_MATCH', 'Field': 'volumeApiName', 'Value': volume_type}
            ]
        )
        price_list = json.loads(response['PriceList'][0])
        price = float(price_list['terms']['OnDemand'][list(price_list['terms']['OnDemand'].keys())[0]]
                     ['priceDimensions'][list(price_list['terms']['OnDemand'][list(price_list['terms']['OnDemand'].keys())[0]]['priceDimensions'].keys())[0]]
                     ['pricePerUnit']['USD'])
        return price
    except:
        return 0.0


@CACHE.memoize(expire=CACHE_TTL)
def get_instance_info(instance_id):
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
        return response['Reservations'][0]['Instances'][0]
    except:
        return None


@CACHE.memoize(expire=CACHE_TTL)
def get_volume_info(volume_id):
    try:
        response = ec2.describe_volumes(VolumeIds=[volume_id])
        return response['Volumes'][0]
    except:
        return None


def send_metric(name, value):
    try:
        requests.post(PROMETHEUS_URL, data=f"{name} {value}", timeout=10)
    except:
        pass


def collect_master_metrics():
    try:
        instance_type = ec2_metadata.instance_type
        instance_id = ec2_metadata.instance_id
        master_price = get_instance_pricing(instance_type, REGION_NAME)
        send_metric("master_node_cost", master_price)

        instance_info = get_instance_info(instance_id)
        if instance_info:
            volumes = instance_info['BlockDeviceMappings']
            total_ebs_cost = 0
            for volume in volumes:
                if 'Ebs' in volume:
                    vol_id = volume['Ebs']['VolumeId']
                    vol_info = get_volume_info(vol_id)
                    if vol_info:
                        vol_type = vol_info['VolumeType']
                        vol_size = vol_info['Size']
                        ebs_price = get_ebs_pricing(vol_type, REGION_NAME)
                        total_ebs_cost += ebs_price * vol_size / 720
        send_metric("ebs_master_cost", total_ebs_cost)
    except:
        pass


def collect_compute_metrics():
    try:
        total_compute_cost = 0
        total_ebs_cost = 0
        for slurm_queue in config['Scheduling']['SlurmQueues']:
            queue_name = slurm_queue['Name']

            for compute_resource in slurm_queue['ComputeResources']:
                if compute_resource['Instances']:
                    instance_type = compute_resource['Instances'][0]['InstanceType']
                    result = subprocess.run(['/opt/slurm/bin/sinfo', '--noheader', '--partition', queue_name],
                                         capture_output=True, text=True, check=True)
                    total_nodes = 0
                    for line in result.stdout.strip().split('\n'):
                        if line and 'idle~' not in line:
                            parts = line.split()
                            if len(parts) >= 4:
                                total_nodes += int(parts[3])

                    if total_nodes > 0:
                        instance_price = get_instance_pricing(instance_type, REGION_NAME)
                        compute_cost = instance_price * total_nodes
                        total_compute_cost += compute_cost
                        ebs_price = get_ebs_pricing('gp3', REGION_NAME)
                        ebs_cost = ebs_price * total_nodes * 100 / 720
                        total_ebs_cost += ebs_cost
        send_metric("compute_nodes_cost", total_compute_cost)
        send_metric("ebs_compute_cost", total_ebs_cost)
    except:
        pass


if __name__ == "__main__":
    collect_master_metrics()
    collect_compute_metrics()