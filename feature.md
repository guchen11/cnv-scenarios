# Feature: Advanced Dashboards and Metadata Collection

# What is this feature:
This feature is aimed at enabling metadata collection details about the env, ocp cluster, hw type, various operator versioning used, storage class details.
These details will be collected and stored as json and sent to elasticsearch index.
its important that the details collected and stored in elasticsearch index will be associated with the metrics that kube-burner collects from the test execution.


# Why this feature is needed:
The aim is to create a series of of advanced grafana dashboards that allow for a technical user to browse executions per workload/scenario and data and be able to compare runs based on metadata information.

An additional dashbaord is needed which allows for comparing two or more runs and identifying what might be different between those runs and highlight the difference.

This feature work will require
- creating a metadatacollector script 
- send metadata that aligns to results to elasticindex index that is connected to profile metric data that is collected per scenario
- build corresponding grafana dashboards as described above.

Please have a look at an example result folder that comes from run-workload.sh
found @/tmp/kube-burner-results/cpu-limits/run-20260226-223616/iteration-1/
note the contained files and jsons
Come up with a plan of how this feature should be implemented and dashboards built

Note that each run results in
```
/tmp/kube-burner-results/cpu-limits/run-20260226-191930/summary.json
{
  "test": "cpu-limits",
  "mode": "sanity",
  "exit_code": 0,
  "results_path": "/tmp/kube-burner-results/cpu-limits/run-20260226-191930",
  "kube_burner_log": "/tmp/kube-burner-results/cpu-limits/run-20260226-191930/kube-burner.log",
  "validation_status": "SUCCESS",
  "validation_files": [
    "/tmp/kube-burner-results/cpu-limits/run-20260226-191930/iteration-1/validation-cpu-limits.json"
  ],
  "duration_seconds": 175,
  "timestamp": "2026-02-26T19:22:25+02:00"
}
```

Validation log:
```
cat /tmp/kube-burner-results/cpu-limits/run-20260226-191930/iteration-1/validation-cpu-limits.json
{
  "testName": "cpu-limits",
  "function": "check_cpu_limits",
  "timestamp": "2026-02-26T19:21:25+02:00",
  "namespace": "sanity-cpu-limits-20260226-191930-2odw",
  "parameters": {
    "label_key": "cpu-limits-test.kube-burner.io/counter",
    "label_value": "counter-1",
    "expected_cpu_cores": 1,
    "vm_count": 1,
    "ssh_validation_enabled": true,
    "total_duration_seconds": 7
},
  "overallStatus": "SUCCESS",
  "exitCode": 0,
  "validations": [
    {"phase": "vm_discovery", "status": "PASS", "message": "Found 1 VMs"},
    {"phase": "vm_spec_cpu_cores", "status": "PASS", "message": "VM spec CPU cores validation (1 cores)"},
    {"phase": "guest_os_cpu_count", "status": "PASS", "message": "Guest OS CPU count validation passed"},
    {"phase": "stress_ng_processes", "status": "PASS", "message": "stress-ng-cpu process count validation passed (1 processes)"}
]
}
```
