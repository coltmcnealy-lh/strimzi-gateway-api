#!/bin/bash

kubectl get secret my-certificate -o json | jq '.data."ca.crt"' | tr -d '"' | base64 --decode > /tmp/ca.crt
keytool -importcert -alias ca -file /tmp/ca.crt -keystore /tmp/strimzi-kafka-truststore.jks -storepass kenobi

JAAS_CONFIG=$(kubectl get secret obiwan -o json | jq '.data."sasl.jaas.config"' | tr -d '"' | base64 --decode)

cat <<EOF > /tmp/kafka-client-config.properties
bootstrap.servers=bootstrap.strimzi.gateway.api.test:9092
sasl.jaas.config=$JAAS_CONFIG
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
ssl.truststore.location=/tmp/strimzi-kafka-truststore.jks
ssl.truststore.password=kenobi
EOF
