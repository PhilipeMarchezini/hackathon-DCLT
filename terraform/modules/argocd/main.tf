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
  })]
}

# A Application raiz não pode viajar no mesmo release do chart: o Helm resolve o
# mapeamento de todos os manifests antes de registrar os CRDs, então um CR de
# argoproj.io/v1alpha1 declarado em extraObjects falha com "ensure CRDs are
# installed first" em um cluster novo. Um segundo release, dependente do
# primeiro, encontra o CRD já registrado.
resource "helm_release" "root_app" {
  name      = "solidarytech-root"
  chart     = "${path.module}/charts/root-app"
  namespace = helm_release.argocd.namespace
  timeout   = 300

  values = [yamlencode({
    repoURL        = var.gitops_repository
    targetRevision = "main"
    path           = "gitops/argocd"
  })]

  depends_on = [helm_release.argocd]
}
