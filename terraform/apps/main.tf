resource "kubernetes_manifest" "go_web_app" {
  manifest = yamldecode(
    file("${path.module}/../../argocd/application.yaml")
  )

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  timeouts {
    create = "10m"
    update = "10m"
    delete = "15m"
  }
}
