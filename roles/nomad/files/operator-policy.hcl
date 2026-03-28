namespace "default" {
  policy       = "write"
  capabilities = ["submit-job", "read-job", "alloc-exec",
                   "alloc-lifecycle", "dispatch-job",
                   "read-logs", "read-fs"]

  variables {
    path "*" {
      capabilities = ["read", "write", "destroy", "list"]
    }
  }
}

node {
  policy = "read"
}
