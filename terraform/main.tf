provider "aws" {
  region = "us-east-1"
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # version = "~> 5.0" # Specify a version constraint if desired
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name        = "${terraform.workspace}-vpc"
    Environment = terraform.workspace
  }
}

resource "aws_subnet" "public_subnet_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "${terraform.workspace}-public-subnet"
    Environment = terraform.workspace
  }
}

resource "aws_subnet" "private_subnet_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name        = "${terraform.workspace}-private-subnet"
    Environment = terraform.workspace
  }
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${terraform.workspace}-igw"
    Environment = terraform.workspace
  }
}

resource "aws_route_table" "public_rtb_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }

  tags = {
    Name        = "${terraform.workspace}-public-rtb"
    Environment = terraform.workspace
  }
}

resource "aws_route_table_association" "public_subnet_assoc_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  subnet_id      = aws_subnet.public_subnet_dev[0].id
  route_table_id = aws_route_table.public_rtb_dev[0].id
}

resource "aws_security_group" "ec2_sg_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  name        = "${terraform.workspace}-ec2-sg"
  description = "Security group for EC2 instance in ${terraform.workspace} environment"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["119.82.139.102/32"] # User's current IP
  }

  ingress {
    description = "SSH from EC2 Instance Connect (us-east-1)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["18.206.107.24/29"] # EIC IP for us-east-1
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${terraform.workspace}-ec2-sg"
    Environment = terraform.workspace
  }
}

data "aws_ami" "amazon_linux_2_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app_server_dev" {
  count = terraform.workspace == "dev" ? 1 : 0

  ami                    = data.aws_ami.amazon_linux_2_dev[0].id
  instance_type          = "t2.micro"
  key_name               = "nhutle-ec2-key-pair"
  subnet_id              = aws_subnet.public_subnet_dev[0].id
  vpc_security_group_ids = [aws_security_group.ec2_sg_dev[0].id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ec2-user

              # Install Docker Compose
              curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
              EOF

  tags = {
    Name        = "${terraform.workspace}-app-server"
    Environment = terraform.workspace
  }
}

# ------------------------------------------------------------------------------
# Production Network Resources 
# ------------------------------------------------------------------------------

# Public Subnets for EKS Worker Nodes in PROD
resource "aws_subnet" "public_eks_node_subnet_a_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24" # New CIDR for prod EKS public subnet A
  availability_zone       = "us-east-1a"   # Choose AZ
  map_public_ip_on_launch = true

  tags = {
    Name                                                       = "${terraform.workspace}-public-eks-node-subnet-a"
    Environment                                                = terraform.workspace
    "kubernetes.io/cluster/${terraform.workspace}-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                                   = "1"
  }
}

resource "aws_subnet" "public_eks_node_subnet_b_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.11.0/24" # New CIDR for prod EKS public subnet B
  availability_zone       = "us-east-1b"   # Different AZ
  map_public_ip_on_launch = true

  tags = {
    Name                                                       = "${terraform.workspace}-public-eks-node-subnet-b"
    Environment                                                = terraform.workspace
    "kubernetes.io/cluster/${terraform.workspace}-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                                   = "1"
  }
}

# Private Subnets for RDS in PROD (already defined, ensure EKS tags are present for potential internal LBs)
resource "aws_subnet" "private_rds_subnet_a_prod" { # Renamed logical for clarity
  count = terraform.workspace == "prod" ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.100.0/24" # Existing CIDR for prod private RDS subnet A
  availability_zone = "us-east-1a"

  tags = {
    Name                                                       = "${terraform.workspace}-private-rds-subnet-a" # Updated tag name
    Environment                                                = terraform.workspace
    "kubernetes.io/cluster/${terraform.workspace}-eks-cluster" = "shared" # For potential internal LBs
    "kubernetes.io/role/internal-elb"                          = "1"      # For potential internal LBs
  }
}

resource "aws_subnet" "private_rds_subnet_b_prod" { # Renamed logical for clarity
  count = terraform.workspace == "prod" ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.101.0/24" # Existing CIDR for prod private RDS subnet B
  availability_zone = "us-east-1b"

  tags = {
    Name                                                       = "${terraform.workspace}-private-rds-subnet-b" # Updated tag name
    Environment                                                = terraform.workspace
    "kubernetes.io/cluster/${terraform.workspace}-eks-cluster" = "shared"
    "kubernetes.io/role/internal-elb"                          = "1"
  }
}

# Public Route Table for PROD (for EKS public nodes and other public resources if any)
resource "aws_route_table" "public_rtb_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id # Assumes main_igw is correctly defined for prod VPC
  }

  tags = {
    Name        = "${terraform.workspace}-public-rtb"
    Environment = terraform.workspace
  }
}

resource "aws_route_table_association" "public_eks_node_subnet_a_assoc_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  subnet_id      = aws_subnet.public_eks_node_subnet_a_prod[0].id
  route_table_id = aws_route_table.public_rtb_prod[0].id
}

resource "aws_route_table_association" "public_eks_node_subnet_b_assoc_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  subnet_id      = aws_subnet.public_eks_node_subnet_b_prod[0].id
  route_table_id = aws_route_table.public_rtb_prod[0].id
}

# ------------------------------------------------------------------------------
# RDS Database for Production (Only created in 'prod' workspace)
# ------------------------------------------------------------------------------

resource "aws_db_subnet_group" "rds_subnet_group_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  name       = "${terraform.workspace}-rds-subnet-group"
  subnet_ids = [aws_subnet.private_rds_subnet_a_prod[0].id, aws_subnet.private_rds_subnet_b_prod[0].id]

  tags = {
    Name        = "${terraform.workspace}-rds-subnet-group"
    Environment = terraform.workspace
  }
}

resource "aws_security_group" "rds_sg_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  name        = "${terraform.workspace}-rds-sg"
  description = "Security group for RDS instance in ${terraform.workspace} environment"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${terraform.workspace}-rds-sg"
    Environment = terraform.workspace
  }
}

resource "random_password" "db_master_password_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  length           = 16
  special          = true
  override_special = "_!%@"
}

resource "aws_secretsmanager_secret" "db_credentials_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  name                    = "${terraform.workspace}/rds/db-credentials"
  description             = "Credentials for RDS database in ${terraform.workspace} environment"
  recovery_window_in_days = 0
  tags = {
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials_version_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  secret_id = aws_secretsmanager_secret.db_credentials_prod[0].id
  secret_string = jsonencode({
    username = "coffeeshopadmin"
    password = random_password.db_master_password_prod[0].result
    engine   = "postgres"
    dbname   = "coffeeshop_prod_db"
  })
}

resource "aws_db_instance" "rds_postgres_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  identifier             = "${terraform.workspace}-postgres-db"
  allocated_storage      = 20
  storage_type           = "gp2"
  engine                 = "postgres"
  engine_version         = "14"
  instance_class         = "db.t3.micro"
  db_name                = "coffeeshop_prod_db"
  username               = jsondecode(aws_secretsmanager_secret_version.db_credentials_version_prod[0].secret_string).username
  password               = jsondecode(aws_secretsmanager_secret_version.db_credentials_version_prod[0].secret_string).password
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group_prod[0].name
  vpc_security_group_ids = [aws_security_group.rds_sg_prod[0].id]

  parameter_group_name = "default.postgres14"
  skip_final_snapshot  = true
  publicly_accessible  = false

  tags = {
    Name        = "${terraform.workspace}-postgres-rds"
    Environment = terraform.workspace
  }

  depends_on = [
    aws_secretsmanager_secret_version.db_credentials_version_prod[0]
  ]
}

# ------------------------------------------------------------------------------
# ECR Repositories for Production (Only created in 'prod' workspace)
# ------------------------------------------------------------------------------

locals {
  app_image_names = [
    "go-coffeeshop-web",
    "go-coffeeshop-proxy",
    "go-coffeeshop-barista",
    "go-coffeeshop-kitchen",
    "go-coffeeshop-counter",
    "go-coffeeshop-product",
  ]
}

resource "aws_ecr_repository" "app_ecr_repos" {
  count                = terraform.workspace == "prod" ? length(local.app_image_names) : 0
  force_delete         = true
  name                 = local.app_image_names[count.index]
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${local.app_image_names[count.index]}-ecr"
    Environment = terraform.workspace
    Project     = "GoCoffeeShop"
  }
}

output "ecr_repository_urls" {
  description = "URLs of the ECR repositories for prod workspace"
  value = terraform.workspace == "prod" ? {
    for repo in aws_ecr_repository.app_ecr_repos : repo.name => repo.repository_url
  } : null
}

output "prod_db_secret_arn" {
  description = "ARN of the Secrets Manager secret for Prod DB credentials"
  value       = terraform.workspace == "prod" ? aws_secretsmanager_secret.db_credentials_prod[0].arn : null
}

# ------------------------------------------------------------------------------
# EKS Cluster for Production (Only created in 'prod' workspace)
# ------------------------------------------------------------------------------

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role_prod" {
  count = terraform.workspace == "prod" ? 1 : 0
  name  = "${terraform.workspace}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = {
    Name        = "${terraform.workspace}-eks-cluster-role"
    Environment = terraform.workspace
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy_prod" {
  count      = terraform.workspace == "prod" ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role_prod[0].name
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSVPCResourceController_prod" {
  count      = terraform.workspace == "prod" ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster_role_prod[0].name
}

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_group_role_prod" {
  count = terraform.workspace == "prod" ? 1 : 0
  name  = "${terraform.workspace}-eks-node-group-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = {
    Name        = "${terraform.workspace}-eks-node-group-role"
    Environment = terraform.workspace
  }
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEKSWorkerNodePolicy_prod" {
  count      = terraform.workspace == "prod" ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group_role_prod[0].name
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEC2ContainerRegistryReadOnly_prod" {
  count      = terraform.workspace == "prod" ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group_role_prod[0].name
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEKS_CNI_Policy_prod" {
  count      = terraform.workspace == "prod" ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group_role_prod[0].name
}

resource "aws_iam_role_policy_attachment" "eks_node_CloudWatchAgentServerPolicy_prod" {
  count      = terraform.workspace == "prod" ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.eks_node_group_role_prod[0].name
}

# EKS Cluster Definition (ensure vpc_config.subnet_ids uses the NEW public EKS node subnets)
resource "aws_eks_cluster" "eks_cluster_prod" {
  count    = terraform.workspace == "prod" ? 1 : 0
  name     = "${terraform.workspace}-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role_prod[0].arn
  version  = "1.29"

  vpc_config {
    subnet_ids = [
      aws_subnet.public_eks_node_subnet_a_prod[0].id, # Use NEW public EKS node subnets
      aws_subnet.public_eks_node_subnet_b_prod[0].id  # Use NEW public EKS node subnets
      # Include the private RDS subnets here too IF you want the EKS control plane to directly manage resources in them (e.g. for some CNI modes or specific LB types)
      # For worker nodes in public subnets, this might not be strictly necessary for basic operation,
      # but EKS often recommends providing all subnets where it might place ENIs (including for LBs).
      # Let's also add the private subnets that RDS uses, for EKS awareness.
      , aws_subnet.private_rds_subnet_a_prod[0].id
      , aws_subnet.private_rds_subnet_b_prod[0].id
    ]
    # endpoint_public_access should be true for nodes in public subnets to easily reach CP
    # endpoint_private_access can be false or true
  }

  tags = {
    Name        = "${terraform.workspace}-eks-cluster"
    Environment = terraform.workspace
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy_prod,
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSVPCResourceController_prod,
  ]
}

# EKS Managed Node Group Definition (Simplified, using NEW public EKS node subnets)
resource "aws_eks_node_group" "eks_node_group_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  cluster_name    = aws_eks_cluster.eks_cluster_prod[0].name
  node_group_name = "${terraform.workspace}-eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role_prod[0].arn
  subnet_ids = [
    aws_subnet.public_eks_node_subnet_a_prod[0].id, # Nodes in NEW public subnets
    aws_subnet.public_eks_node_subnet_b_prod[0].id  # Nodes in NEW public subnets
  ]

  instance_types = ["t3.small"]
  disk_size      = 20

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_AmazonEKSWorkerNodePolicy_prod,
    aws_iam_role_policy_attachment.eks_node_AmazonEC2ContainerRegistryReadOnly_prod,
    aws_iam_role_policy_attachment.eks_node_AmazonEKS_CNI_Policy_prod,
  ]

  tags = {
    Name        = "${terraform.workspace}-eks-worker-nodes"
    Environment = terraform.workspace
  }
}

# RDS Security Group Ingress Rule (still allowing access from EKS Cluster SG)
resource "aws_security_group_rule" "rds_ingress_from_eks_cluster_sg_prod" {
  count = terraform.workspace == "prod" ? 1 : 0

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_sg_prod[0].id
  source_security_group_id = aws_eks_cluster.eks_cluster_prod[0].vpc_config[0].cluster_security_group_id
  description              = "Allow PostgreSQL access from EKS cluster SG"
}

# Outputs for EKS (if needed)
output "eks_cluster_endpoint_prod" {
  description = "Endpoint for the EKS cluster an_prod workspace"
  value       = terraform.workspace == "prod" && length(aws_eks_cluster.eks_cluster_prod) > 0 ? aws_eks_cluster.eks_cluster_prod[0].endpoint : "N/A"
}

output "eks_cluster_ca_certificate_prod" {
  description = "Base64 encoded CA certificate for the EKS cluster an_prod workspace"
  value       = terraform.workspace == "prod" && length(aws_eks_cluster.eks_cluster_prod) > 0 ? aws_eks_cluster.eks_cluster_prod[0].certificate_authority[0].data : "N/A"
}

output "eks_node_group_role_arn_prod" {
  description = "ARN of the EKS node group role for prod"
  value       = terraform.workspace == "prod" && length(aws_iam_role.eks_node_group_role_prod) > 0 ? aws_iam_role.eks_node_group_role_prod[0].arn : "N/A"
}