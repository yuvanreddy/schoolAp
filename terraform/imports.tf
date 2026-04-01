import {
  to = module.eks.aws_eks_addon.this["coredns"]
  id = "edusphere-eks:coredns"
}

import {
  to = module.eks.aws_eks_addon.this["vpc-cni"]
  id = "edusphere-eks:vpc-cni"
}

import {
  to = module.eks.aws_eks_addon.this["aws-ebs-csi-driver"]
  id = "edusphere-eks:aws-ebs-csi-driver"
}

import {
  to = module.eks.aws_eks_addon.this["kube-proxy"]
  id = "edusphere-eks:kube-proxy"
}
