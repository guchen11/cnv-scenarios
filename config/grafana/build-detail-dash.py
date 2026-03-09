#!/usr/bin/env python3
"""Build cnv-run-detail.json from cnv-run-explorer.json with modifications."""
import json

with open("config/grafana/cnv-run-explorer.json") as f:
    dash = json.load(f)

dash["title"] = "CNV Run Detail"
dash["uid"] = "cnv-run-detail"
dash["description"] = "Deep-dive into a single CNV test run with validation results, Prometheus metrics, VMI lifecycle waterfall, and per-worker analysis"
dash["tags"] = ["cnv", "detail"]
dash["links"] = [
    {"icon": "external link", "tags": ["cnv"], "title": "Explorer", "tooltip": "Browse all runs", "type": "link", "url": "/d/cnv-run-explorer/cnv-run-explorer", "targetBlank": True},
    {"icon": "external link", "tags": ["cnv"], "title": "Comparison", "tooltip": "Compare runs", "type": "link", "url": "/d/cnv-run-comparison/cnv-run-comparison", "targetBlank": True},
]

meta_q = "metricName.keyword: metadata AND uuid.keyword: $uuid"

def mk_es_target(query, uid="${DS_CNV_ES}", raw_size=1):
    return {"bucketAggs": [], "datasource": {"type": "elasticsearch", "uid": uid}, "metrics": [{"id": "1", "settings": {"size": str(raw_size)}, "type": "raw_data"}], "query": query, "refId": "A", "timeField": "timestamp"}

def mk_es_metrics_target(query, raw_size=1):
    return mk_es_target(query, uid="${DS_CNV_METRICS}", raw_size=raw_size)

# Variables
dash["templating"]["list"] = [
    {"current": {}, "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_ES}"}, "definition": '{"find": "terms", "field": "testName.keyword", "query": "metricName.keyword: metadata"}', "hide": 0, "includeAll": False, "label": "Workload", "multi": False, "name": "workload", "options": [], "query": '{"find": "terms", "field": "testName.keyword", "query": "metricName.keyword: metadata"}', "refresh": 2, "skipUrlSync": False, "sort": 0, "type": "query"},
    {"current": {}, "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_ES}"}, "definition": '{"find": "terms", "field": "uuid.keyword", "query": "metricName.keyword: metadata AND testName.keyword: $workload"}', "hide": 0, "includeAll": False, "label": "UUID", "multi": False, "name": "uuid", "options": [], "query": '{"find": "terms", "field": "uuid.keyword", "query": "metricName.keyword: metadata AND testName.keyword: $workload"}', "refresh": 1, "skipUrlSync": False, "sort": 0, "type": "query"},
    {"allValue": "*", "current": {}, "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "definition": '{"find": "terms", "field": "labels.node.keyword", "query": "metricName.keyword: nodeRoles AND labels.role.keyword: worker AND uuid.keyword: $uuid"}', "hide": 0, "includeAll": True, "label": "Worker", "multi": True, "name": "worker", "options": [], "query": '{"find": "terms", "field": "labels.node.keyword", "query": "metricName.keyword: nodeRoles AND labels.role.keyword: worker AND uuid.keyword: $uuid"}', "refresh": 2, "skipUrlSync": False, "sort": 0, "type": "query"},
    {"current": {"selected": True, "text": "P99", "value": "P99"}, "hide": 0, "includeAll": False, "label": "Latency Percentile", "multi": False, "name": "latencyPercentile", "options": [{"selected": True, "text": "P99", "value": "P99"}, {"selected": False, "text": "P95", "value": "P95"}, {"selected": False, "text": "P50", "value": "P50"}], "query": "P99 : P99,P95 : P95,P50 : P50", "skipUrlSync": False, "type": "custom"},
]

# Panels - build from scratch
panels = []
y = 0

def stat(id, title, field, x, w=3, **extra):
    p = {"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_ES}"}, "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}, "overrides": []}, "gridPos": {"h": 3, "w": w, "x": x, "y": y}, "id": id, "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "reduceOptions": {"calcs": ["lastNotNull"], "fields": field, "values": False}, "textMode": "value", "wideLayout": True}, "targets": [mk_es_target(meta_q)], "title": title, "type": "stat"}
    p.update(extra)
    return p

# Row 1
panels.append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 100, "title": "Run Identity", "type": "row"})
y += 1
result_mappings = [{"options": {"SUCCESS": {"color": "green", "index": 0}}, "type": "value"}, {"options": {"FAILURE": {"color": "red", "index": 0}}, "type": "value"}]
for i, (tid, t, f, tf) in enumerate([(1, "Test Result", "/testResult/", "cluster"), (2, "OCP Version", "/ocpVersion/", "cluster"), (3, "CNV Version", "/cnvVersion/", "operators"), (4, "Platform", "/platform/", "cluster"), (5, "Network Type", "/networkType/", "cluster"), (6, "Workers", "/workers/", "nodes"), (7, "Duration", "/durationSeconds/", None), (8, "VM Count", "/vmCount/", "testConfig")]):
    ex = {}
    if t == "Test Result":
        ex = {"fieldConfig": {"defaults": {"mappings": result_mappings, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}}, "options": {"colorMode": "background"}}
    elif t == "Duration":
        ex = {"fieldConfig": {"defaults": {"unit": "s", "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}}
    elif tf:
        ex = {"transformations": [{"id": "extractFields", "options": {"format": "json", "replace": True, "source": tf}}]}
    panels.append(stat(tid, t, f, i * 3, **ex))
y += 4

# Row 2 - Validation
panels.append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 101, "title": "Validation Results", "type": "row"})
y += 1
val_q = "metricName.keyword: validation AND uuid.keyword: $uuid"
overall_mappings = [{"options": {"SUCCESS": {"color": "green", "index": 0}}, "type": "value"}, {"options": {"FAILURE": {"color": "red", "index": 0}}, "type": "value"}]
overall_status = {
    "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"},
    "fieldConfig": {"defaults": {"mappings": overall_mappings, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}},
    "gridPos": {"h": 4, "w": 6, "x": 0, "y": y},
    "id": 10,
    "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "/overallStatus/", "values": False}, "textMode": "value", "wideLayout": True},
    "targets": [mk_es_metrics_target(val_q)],
    "title": "Overall Status",
    "type": "stat",
}
panels.append(overall_status)
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False}}}, "gridPos": {"h": 8, "w": 18, "x": 6, "y": y}, "id": 11, "options": {"cellHeight": "sm", "footer": {"countRows": False, "fields": "", "reducer": ["sum"], "show": False}, "showHeader": True}, "targets": [mk_es_metrics_target(val_q)], "title": "Validation Phases", "type": "table"})
y += 8

# Row 3 - VMI Latency
panels.append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 102, "title": "VMI Latency", "type": "row"})
y += 1
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False}, "unit": "ms"}}, "gridPos": {"h": 8, "w": 24, "x": 0, "y": y}, "id": 20, "options": {"cellHeight": "sm", "footer": {"countRows": False, "fields": "", "reducer": ["sum"], "show": False}, "showHeader": True}, "targets": [mk_es_metrics_target("uuid.keyword: $uuid AND metricName.keyword: vmiLatencyQuantilesMeasurement", raw_size=500)], "transformations": [{"id": "extractFields", "options": {"format": "json", "replace": True, "source": "labels"}}, {"id": "organize", "options": {"excludeByName": {"_id": True, "_index": True, "_type": True, "metricName": True, "uuid": True, "timestamp": True}, "renameByName": {"vmName": "VM", "P50": "P50 (ms)", "P95": "P95 (ms)", "P99": "P99 (ms)"}}}], "title": "VMI Latency Table", "type": "table"})
y += 8

# Row 4 - Worker Hardware
panels.append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 103, "title": "Worker Node Hardware", "type": "row"})
y += 1
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_ES}"}, "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False}}}, "gridPos": {"h": 6, "w": 24, "x": 0, "y": y}, "id": 25, "options": {"cellHeight": "sm", "footer": {"countRows": False, "fields": "", "reducer": ["sum"], "show": False}, "showHeader": True}, "targets": [mk_es_target(meta_q)], "transformations": [{"id": "extractFields", "options": {"format": "json", "replace": True, "source": "nodes"}}, {"id": "organize", "options": {"excludeByName": {"_id": True, "_index": True, "_type": True, "metricName": True}, "renameByName": {"workers": "Worker Count", "workerDetails": "Details"}}}], "title": "Worker Details Table", "type": "table"})
y += 6

# Row 5 - Operator Versions
panels.append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 104, "title": "Operator Versions", "type": "row"})
y += 1
for i, (pid, t, f) in enumerate([(31, "CNV", "/cnvVersion/"), (32, "HCO", "/hcoVersion/"), (33, "ODF", "/odfVersion/"), (34, "SR-IOV", "/sriovVersion/"), (35, "NMState", "/nmstateVersion/")]):
    w = 5 if i < 4 else 4
    panels.append(stat(pid, t, f, i * 5, w=w, transformations=[{"id": "extractFields", "options": {"format": "json", "replace": True, "source": "operators"}}]))
y += 4

# Row 6 - Cluster Status (collapsed)
panels.append({"collapsed": True, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 105, "title": "Cluster Status", "type": "row"})
y += 1
for i, (pid, t, mq) in enumerate([(40, "Namespaces", "namespaceCount"), (41, "Pod Count", "podStatusCount"), (42, "Node Count", "nodeStatus")]):
    q = "uuid.keyword: $uuid AND metricName.keyword: " + mq
    cluster_stat = {"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}, "gridPos": {"h": 4, "w": 8, "x": i * 8, "y": y}, "id": pid, "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "/value/", "values": False}, "textMode": "value", "wideLayout": True}, "targets": [{"bucketAggs": [], "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "metrics": [{"field": "value", "id": "1", "type": "avg"}], "query": q, "refId": "A", "timeField": "timestamp"}], "title": t, "type": "stat"}
    panels.append(cluster_stat)
y += 5

# Row 7 - Worker repeat
panels.append({"collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "id": 109, "repeat": "worker", "repeatDirection": "h", "title": "Worker Node: $worker", "type": "row"})
y += 1
buckets = [{"field": "labels.pod.keyword", "id": "3", "settings": {"min_doc_count": "1", "order": "desc", "orderBy": "_count", "size": "20"}, "type": "terms"}, {"field": "timestamp", "id": "2", "settings": {"interval": "auto", "min_doc_count": "0"}, "type": "date_histogram"}]
ts = {"fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"axisBorderShow": False, "axisCenteredZero": False, "axisColorMode": "text", "drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "auto", "spanNulls": True, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}}}, "overrides": []}, "options": {"legend": {"calcs": [], "displayMode": "list", "placement": "bottom", "showLegend": True}, "tooltip": {"mode": "multi", "sort": "none"}}}
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, **ts, "gridPos": {"h": 8, "w": 12, "x": 0, "y": y}, "id": 80, "targets": [{"bucketAggs": buckets, "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "metrics": [{"field": "value", "id": "1", "type": "avg"}], "query": "uuid.keyword: $uuid AND metricName.keyword: podCPU AND labels.node.keyword: $worker", "refId": "A", "timeField": "timestamp"}], "title": "Container CPU", "type": "timeseries"})
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, **ts, "fieldConfig": {"defaults": {**ts["fieldConfig"]["defaults"], "unit": "bytes"}, "overrides": []}, "gridPos": {"h": 8, "w": 12, "x": 12, "y": y}, "id": 81, "targets": [{"bucketAggs": buckets, "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "metrics": [{"field": "value", "id": "1", "type": "avg"}], "query": "uuid.keyword: $uuid AND metricName.keyword: podMemory AND labels.node.keyword: $worker", "refId": "A", "timeField": "timestamp"}], "title": "Container Memory", "type": "timeseries"})
y += 8
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, **ts, "gridPos": {"h": 8, "w": 12, "x": 0, "y": y}, "id": 82, "targets": [{"bucketAggs": [{"field": "labels.mode.keyword", "id": "3", "settings": {"min_doc_count": "1", "order": "desc", "orderBy": "_count", "size": "10"}, "type": "terms"}, {"field": "timestamp", "id": "2", "settings": {"interval": "auto", "min_doc_count": "0"}, "type": "date_histogram"}], "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "metrics": [{"field": "value", "id": "1", "type": "avg"}], "query": "uuid.keyword: $uuid AND metricName.keyword: nodeCPU AND labels.instance.keyword: $worker", "refId": "A", "timeField": "timestamp"}], "title": "Node CPU", "type": "timeseries"})
panels.append({"datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, **ts, "fieldConfig": {"defaults": {**ts["fieldConfig"]["defaults"], "unit": "bytes"}, "overrides": []}, "gridPos": {"h": 8, "w": 12, "x": 12, "y": y}, "id": 83, "targets": [{"bucketAggs": [{"field": "timestamp", "id": "2", "settings": {"interval": "auto", "min_doc_count": "0"}, "type": "date_histogram"}], "datasource": {"type": "elasticsearch", "uid": "${DS_CNV_METRICS}"}, "metrics": [{"field": "value", "id": "1", "type": "avg"}], "query": "uuid.keyword: $uuid AND metricName.keyword: nodeMemoryAvailable AND labels.instance.keyword: $worker", "refId": "A", "timeField": "timestamp"}], "title": "Node Memory", "type": "timeseries"})

dash["panels"] = panels

with open("config/grafana/cnv-run-detail.json", "w") as f:
    json.dump(dash, f, indent=2)

print("Built cnv-run-detail.json with", len(panels), "panels")
