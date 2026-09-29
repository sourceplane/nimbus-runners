# Public-subnet-only VPC. Runners get a public IPv4 ($0.005/h while running)
# instead of sitting behind a NAT gateway (~$33/month idle plus $0.045/GB),
# which alone would cost more than half the budget. No ingress is allowed:
# the runner security group (module-managed) is egress-only, and debugging is
# through SSM Session Manager.

resource "aws_vpc" "runners" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.prefix }
}

resource "aws_internet_gateway" "runners" {
  vpc_id = aws_vpc.runners.id

  tags = { Name = local.prefix }
}

resource "aws_subnet" "public" {
  for_each = { for i, az in local.availability_zones : az => i }

  vpc_id                  = aws_vpc.runners.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(local.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = true

  tags = { Name = "${local.prefix}-public-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.runners.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.runners.id
  }

  tags = { Name = "${local.prefix}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Free gateway endpoint: S3 traffic (SSM agent, lambda artifacts, any S3
# cache) stays on the AWS network, with no public-IP data path.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.runners.id
  service_name      = "com.amazonaws.${local.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = { Name = "${local.prefix}-s3" }
}

# The default security group of the VPC is locked down; runners use the
# module-managed group.
resource "aws_default_security_group" "runners" {
  vpc_id = aws_vpc.runners.id
}
