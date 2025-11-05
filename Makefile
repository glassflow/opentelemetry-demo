.PHONY: repos ns install telemetry uninstall status pf-hyperdx pf-glassflow deploy-pipelines create-clickhouse-tables ensure-kafka-consumer-offsets

# Use a single shell per recipe to allow multi-line loops/conditionals
SHELL := /bin/bash
.ONESHELL:

# Namespace configuration
KAFKA_NS ?= kafka
OTEL_NS ?= otel
GLASSFLOW_NS ?= glassflow
HYPERDX_NS ?= hyperdx

HELM_VALUES := k8s/helm-values

repos:
	helm repo add bitnami https://charts.bitnami.com/bitnami || true
	helm repo add opentelemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
	helm repo add glassflow https://glassflow.github.io/charts || true
	helm repo add hyperdx https://hyperdxio.github.io/helm-charts || true
	helm repo update

repos-remove:
	helm repo remove bitnami || true
	helm repo remove opentelemetry || true
	helm repo remove glassflow || true
	helm repo remove hyperdx || true

ns:
	kubectl create namespace $(KAFKA_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace $(OTEL_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace $(GLASSFLOW_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace $(HYPERDX_NS) --dry-run=client -o yaml | kubectl apply -f -

ns-remove:
	kubectl delete namespace $(KAFKA_NS) || true
	kubectl delete namespace $(OTEL_NS) || true
	kubectl delete namespace $(GLASSFLOW_NS) || true
	kubectl delete namespace $(HYPERDX_NS) || true

install:
	# Kafka (Bitnami)
	helm install kafka oci://registry-1.docker.io/bitnamicharts/kafka -n $(KAFKA_NS) -f $(HELM_VALUES)/kafka.values.yaml --create-namespace=false || true
	
	# OpenTelemetry Collector
	helm install otel opentelemetry/opentelemetry-collector -n $(OTEL_NS) -f $(HELM_VALUES)/otel-collector.values.yaml --create-namespace=false || true
	
	# Glassflow
	helm install glassflow glassflow/glassflow-etl -n $(GLASSFLOW_NS) -f $(HELM_VALUES)/glassflow.values.yaml --create-namespace=false || true
	
	# HyperDX (with embedded ClickHouse)
	helm install hyperdx hyperdx/hdx-oss-v2 -n $(HYPERDX_NS) -f $(HELM_VALUES)/hyperdx.values.yaml --create-namespace=false || true

telemetry:
	kubectl apply -f k8s/telemetry/

telemetry-remove:
	kubectl delete -f k8s/telemetry/ || true

uninstall:
	-helm uninstall hyperdx -n $(HYPERDX_NS)
	-helm uninstall glassflow -n $(GLASSFLOW_NS)
	-helm uninstall otel -n $(OTEL_NS)
	-helm uninstall kafka -n $(KAFKA_NS)

status:
	kubectl get pods -n $(KAFKA_NS)
	kubectl get pods -n $(OTEL_NS)
	kubectl get pods -n $(GLASSFLOW_NS)
	kubectl get pods -n $(HYPERDX_NS)

pf-hyperdx:
	kubectl -n $(HYPERDX_NS) port-forward svc/hyperdx-hdx-oss-v2-app 3000:3000

pf-glassflow-ui:
	kubectl -n $(GLASSFLOW_NS) port-forward svc/glassflow-api 8080:8080

deploy-pipelines:
	# Port-forward Glassflow API and deploy all pipelines
	set -e; \
	( kubectl -n $(GLASSFLOW_NS) port-forward svc/glassflow-api 8081:8081 >/dev/null 2>&1 & echo $$! > /tmp/gf_pf.pid ); \
	sleep 3; \
	for f in glassflow-pipelines/*.json; do \
		echo "Deploying $$f"; \
		curl -sfS -X POST \
		  -H 'Content-Type: application/json' \
		  -d @"$$f" \
		  http://127.0.0.1:8081/api/v1/pipeline; \
	done; \
	kill $$(cat /tmp/gf_pf.pid) || true; \
	rm -f /tmp/gf_pf.pid

create-clickhouse-tables:
	# Create OpenTelemetry tables in ClickHouse
	kubectl exec -i -n $(HYPERDX_NS) deploy/hyperdx-hdx-oss-v2-clickhouse -- \
		clickhouse-client --multiquery < clickhouse/create_otel_tables.sql

ensure-kafka-consumer-offsets:
	# Ensure __consumer_offsets topic exists (required for consumer groups)
	@echo "Checking if __consumer_offsets topic exists..."
	@if kubectl exec -n $(KAFKA_NS) kafka-controller-0 -- \
		kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null | grep -q "__consumer_offsets"; then \
		echo "__consumer_offsets topic already exists"; \
	else \
		echo "Creating __consumer_offsets topic..."; \
		kubectl exec -n $(KAFKA_NS) kafka-controller-0 -- \
			kafka-topics.sh --bootstrap-server localhost:9092 --create \
			--topic __consumer_offsets --partitions 50 --replication-factor 1 \
			--config cleanup.policy=compact 2>&1 || true; \
	fi

deploy-stack:
	# Prepare repos, namespaces and install stack
	$(MAKE) repos ns install

	# Wait for Kafka to be ready and ensure __consumer_offsets topic exists
	kubectl rollout status -n $(KAFKA_NS) statefulset/kafka-controller --timeout=5m
	$(MAKE) ensure-kafka-consumer-offsets

	# Wait for ClickHouse to be ready
	kubectl rollout status -n $(HYPERDX_NS) deploy/hyperdx-hdx-oss-v2-clickhouse --timeout=5m
	$(MAKE) create-clickhouse-tables

	# Wait for GlassFlow API to be ready
	kubectl rollout status -n $(GLASSFLOW_NS) deploy/glassflow-api --timeout=5m
	$(MAKE) deploy-pipelines

	# Deploy telemetry generators
	$(MAKE) telemetry

delete-stack:
	# Uninstall stack
	$(MAKE) uninstall

	# Delete telemetry generators
	$(MAKE) telemetry-remove

	# Remove namespaces
	$(MAKE) ns-remove

	# Remove repos
	$(MAKE) repos-remove