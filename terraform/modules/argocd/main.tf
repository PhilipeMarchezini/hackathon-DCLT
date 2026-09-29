resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.5.7"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 900

  values = [yamlencode({
    server = { service = { type = "ClusterIP" } }
    extraObjects = [{
      apiVersion = "argoproj.io/v1alpha1"
      kind       = "Application"
      metadata   = { name = "solidarytech-root", namespace = "argocd" }
      spec = {
        project     = "default"
        source      = { repoURL = var.gitops_repository, targetRevision = "main", path = "gitops/argocd" }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }]
  })]
}
