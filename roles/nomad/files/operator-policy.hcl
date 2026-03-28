namespace "default" {
  policy = "write"

  variables {
    path "*" {
      capabilities = ["read", "write", "destroy", "list"]
    }
  }
}

node {
  policy = "read"
}
