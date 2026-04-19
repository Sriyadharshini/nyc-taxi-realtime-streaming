# nyc-taxi-realtime-streaming
End to End Streaming project
nyc-taxi-realtime-streaming/
  ├── infra/
  │     └── bicep/
  │           ├── main.bicep
  │           ├── storage.bicep
  │           ├── eventhubs.bicep
  │           ├── databricks.bicep
  │           ├── sql.bicep
  │           └── keyvault.bicep
  ├── notebooks/
  │     ├── producer/
  │     │     └── taxi_event_producer.py
  │     └── streaming/
  │           ├── bronze_stream.py
  │           ├── silver_stream.py
  │           └── gold_stream.py
  ├── sql/
  │     └── setup.sql
  ├── adf/
  ├── docs/
  │     └── architecture.md
  └── README.md
