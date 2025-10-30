resource "aws_vpc" "main" {
    cidr_block = var.vpc_cidr
    enable_dns_support = true
    enable_dns_hostnames = true

    tags = {
        Name = "case-study-2-vpc"
  }
}
# Discover AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "case-study-2-igw"
    }
}

#public subnets
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "case-study-2-public-${count.index + 1}"
    Tier = "public"
  }
}

#private app subnets (for ECS, etc.)
resource "aws_subnet" "app" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "case-study-2-app-${count.index + 1}"
    Tier = "app"
  }
}

#private data subnets (for RDS)
resource "aws_subnet" "data" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.data_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "case-study-2-data-${count.index + 1}"
    Tier = "data"
  }
}

#public route table (to IGW) + associations
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "case-study-2-public-rt"
    }
}

resource "aws_route_table_association" "public_assoc" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#single NAT in AZ 0 to save cost
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "case-study-2-nat-eip"
  }
}

//NAT that depends on the igw
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "case-study-2-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

#private APP route table
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name = "case-study-2-app-rt"
    }
}

resource "aws_route_table_association" "app_assoc" {
  count          = var.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

#private DATA route table
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "case-study-2-data-rt"
    }
}

resource "aws_route_table_association" "data_assoc" {
  count          = var.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

#security group for ECS tasks - app
resource "aws_security_group" "ecs_tasks" {
  name        = "case-study-2-ecs-tasks-sg"
  description = "Allow egress for ECS tasks"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "case-study-2-ecs-tasks-sg"
  }
}

#security group for RDS
resource "aws_security_group" "rds" {
  name        = "case-study-2-rds-sg"
  description = "Allow Postgres from ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
    description     = "Postgres from ECS tasks"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "case-study-2-rds-sg"
    }
}
//private zone
resource "aws_route53_zone" "internal" {
  name = var.internal_domain
  vpc {
    vpc_id = aws_vpc.main.id
  }
  tags = {
    Name = "case-study-2-phz"
    }
}

#subnet group for RDS that uses the private db subnets
resource "aws_db_subnet_group" "rds" {
  name       = "case-study-2-rds-subnets"
  subnet_ids = [for s in aws_subnet.data : s.id]
  tags = {
    Name = "case-study-2-rds-subnets"
    }
}

resource "aws_db_instance" "postgres" {
  identifier                = "case-study-2-db"
  engine                    = "postgres"
  engine_version            = "17.6"
  instance_class            = "db.t4g.micro"
  username                  = var.db_username
  password                  = var.db_password
  db_name                   = var.db_name

  allocated_storage         = 20
  storage_encrypted         = true
  backup_retention_period   = 7

  db_subnet_group_name      = aws_db_subnet_group.rds.name
  vpc_security_group_ids    = [aws_security_group.rds.id]

  publicly_accessible       = false
  multi_az                  = true
  deletion_protection       = false
  skip_final_snapshot       = true

  tags = {
    Name = "case-study-2-postgres"
  }
}
resource "aws_ecr_repository" "collector"{
    name = "case-study-2-collector"
    image_tag_mutability = "MUTABLE"
    image_scanning_configuration {
      scan_on_push = true
    }
    tags = {
        Name = "case-study-2-collector-ecr"
    }
}
resource "aws_ecs_cluster" "main" {
    name = "case-study-2-ecs"
    tags = {
        Name = "case-study-2-ecs"
    }
  
}
resource "aws_route53_record" "db_record" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.internal_domain}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_db_instance.postgres.address]
}
