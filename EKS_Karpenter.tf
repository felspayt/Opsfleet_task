## Terraform Variables

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "custom-test-vpc"
}

variable "cluster_name" {
  description = "EKS Cluster Name"
  type        = string
  default     = "custom-test-eks"
}

variable "eks_version" {
  description = "EKS Cluster Version"
  type        = string
  default     = "latest"
}

variable "azs" {
  description = "Availability Zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "instance_types" {
  description = "List of EC2 instance types for Karpenter"
  type        = list(string)
  default     = ["m6a.large", "c7g.large"]
}

variable "karpenter_role_name" {
  description = "IAM Role name for Karpenter"
  type        = string
  default     = "karpenter-role"
}

variable "eks_role_name" {
  description = "IAM Role name for EKS"
  type        = string
  default     = "eks-cluster-role"
}

## Locals
locals {
  cluster_tags = {
    "Name"      = var.cluster_name
    "Terraform" = "true"
  }
}

## Terraform Provider
provider "aws" {
  region = var.region
}

terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
  }
}


## Terraform Modules
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name            = var.vpc_name
  cidr            = "10.0.0.0/16"
  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.eks_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  enable_irsa = true
}

resource "aws_iam_role" "eks_role" {
  name = var.eks_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "karpenter_role" {
  name = var.karpenter_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_policy" {
  role       = aws_iam_role.karpenter_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_security_group" "eks_sg" {
  name_prefix = "eks-sg-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Deploy Karpenter using Helm
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "https://charts.karpenter.sh"
  chart      = "karpenter"
  namespace  = "karpenter"

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "controller.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "controller.clusterCaCertificate"
    value = module.eks.cluster_certificate_authority_data
  }

  depends_on = [module.eks]
}

# Karpenter Provisioner Configuration
resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body  = <<YAML
apiVersion: karpenter.k8s.aws/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  provider:
    subnetSelector:
      karpenter.sh/discovery: "${var.cluster_name}"
    securityGroupSelector:
      karpenter.sh/discovery: "${var.cluster_name}"
  requirements:
    - key: "node.kubernetes.io/instance-type"
      operator: In
      values: ${jsonencode(var.instance_types)}
    - key: "topology.kubernetes.io/zone"
      operator: In
      values: ${jsonencode(var.azs)}
    - key: "kubernetes.io/arch"
      operator: In
      values: ["arm64", "amd64"]
  limits:
    resources:
      cpu: "1000"
  ttlSecondsAfterEmpty: 30
YAML
  depends_on = [helm_release.karpenter]
}
