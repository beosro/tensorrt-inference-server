#!/bin/bash
# Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

REPO_VERSION=${NVIDIA_TENSORRT_SERVER_VERSION}
if [ "$#" -ge 1 ]; then
    REPO_VERSION=$1
fi
if [ -z "$REPO_VERSION" ]; then
    echo -e "Repository version must be specified"
    echo -e "\n***\n*** Test Failed\n***"
    exit 1
fi

export CUDA_VISIBLE_DEVICES=0

CLIENT_LOG="./client.log"
PERF_CLIENT=../clients/perf_client

DATADIR="/data/inferenceserver/${REPO_VERSION}/tf_model_store"

SERVER=/opt/tensorrtserver/bin/trtserver
SERVER_ARGS="--log-verbose=1 --model-repository=s3://localhost:4572/demo-bucket"
SERVER_LOG="./inference_server.log"
source ../common/util.sh

rm -f *.log*

## Setup local MINIO server
(wget https://dl.min.io/server/minio/release/linux-amd64/minio && \
    chmod +x minio && \
    mv minio /usr/local/bin && \
    mkdir /usr/local/share/minio && \
    mkdir /etc/minio)

export MINIO_ACCESS_KEY="minio"
MINIO_VOLUMES="/usr/local/share/minio/"
MINIO_OPTS="-C /etc/minio --address localhost:4572"
export MINIO_SECRET_KEY="miniostorage"

(curl -O https://raw.githubusercontent.com/minio/minio-service/master/linux-systemd/minio.service && \
    mv minio.service /etc/systemd/system)

# Start minio server
/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES &
MINIO_PID=$!

export AWS_ACCESS_KEY_ID=minio && \
    export AWS_SECRET_ACCESS_KEY=miniostorage

# create and add data to bucket
python -m pip install awscli-local && \
    awslocal --endpoint-url=http://localhost:4572 s3 mb s3://demo-bucket && \
    awslocal s3 sync $DATADIR s3://demo-bucket

RET=0

run_server
if [ "$SERVER_PID" == "0" ]; then
    echo -e "\n***\n*** Failed to start $SERVER\n***"
    cat $SERVER_LOG
    # Kill minio server
    kill $MINIO_PID
    wait $MINIO_PID
    exit 1
fi

set +e
for MODEL_NAME in resnet_v1_50_graphdef resnet_v1_50_savedmodel; do
  $PERF_CLIENT -m $MODEL_NAME -p 3000 -t 1 >$CLIENT_LOG 2>&1
  if [ $? -ne 0 ]; then
      echo -e "\n***\n*** Test Failed\n***"
      cat $CLIENT_LOG
      RET=1
  fi
done
set -e

kill $SERVER_PID
wait $SERVER_PID

# Kill minio server
kill $MINIO_PID
wait $MINIO_PID

if [ $RET -eq 0 ]; then
  echo -e "\n***\n*** Test Passed\n***"
else
  echo -e "\n***\n*** Test Failed\n***"
fi

exit $RET
