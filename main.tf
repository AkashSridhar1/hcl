data "aws_availability_zones" "available" {
  state = "available"
}

resource "random_string" "name" {
  length   = 4
  upper    = false
  lower    = true
  numeric  = true
  special  = false
}

resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "${var.prefix}-vpc-${random_string.name.result}"
  }
}

# Create a single Public Subnet
resource "aws_subnet" "hcl_subnet" {
  vpc_id                  = aws_vpc.my_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "${var.prefix}-subnet1-${random_string.name.result}"
  }
}

resource "aws_subnet" "hcl_subnet_2" {
  vpc_id                  = aws_vpc.my_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "${var.prefix}-subnet2-${random_string.name.result}"
  }
}

resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "${var.prefix}-igw-${random_string.name.result}"
  }
}

# Create a Route Table
resource "aws_route_table" "my_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"   # Route all outbound traffic to the internet
    gateway_id = aws_internet_gateway.my_igw.id   # Reference the IGW
  }

  tags = {
    Name = "${var.prefix}-rt-${random_string.name.result}"
  }
}

# Associate the Route Table with the Public Subnet
resource "aws_route_table_association" "my_route_table_association" {
  subnet_id      = aws_subnet.hcl_subnet.id
  route_table_id = aws_route_table.my_route_table.id
}

resource "aws_security_group" "my_security_group" {
  name = "${var.prefix}-sg-${random_string.name.result}"
  vpc_id = aws_vpc.my_vpc.id

  # Allow inbound traffic on port 80 (HTTP)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Allow access from anywhere (change as needed)
  }

  # Allow outbound traffic to any destination
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "my_cluster" {
  name = "${var.prefix}-${var.cluster_name}-${random_string.name.result}"
}

# Create ECS Task Definition for Fargate
resource "aws_ecs_task_definition" "my_task" {
  family                = "${var.prefix}-${var.task_name}-${random_string.name.result}"
  network_mode          = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024  # Define CPU at the task level
  memory                   = 2048
  execution_role_arn = aws_iam_role.task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.prefix}-${var.container_name}-${random_string.name.result}"
      image     = var.ecs_image
      cpu        = var.ecs_cpu
      memory     = var.ecs_memory
      essential = true
      portMappings = [
        {
          containerPort = var.ecs_port
          hostPort      = var.ecs_port
        }
      ]
    }
])
depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy_attachment
  ]
}




# Create ECS Service using a single subnet
resource "aws_ecs_service" "my_service" {
  name            = "${var.prefix}-${var.service_name}-${random_string.name.result}"
  cluster         = aws_ecs_cluster.my_cluster.id
  task_definition = aws_ecs_task_definition.my_task.arn
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.dash_subnet.id,aws_subnet.dash_subnet_2.id]  # Single subnet
    security_groups = [aws_security_group.my_security_group.id]
    assign_public_ip = true
  }

   load_balancer {
    target_group_arn = aws_lb_target_group.ecs_tg.arn  # Reference the target group ARN
    container_name   = "${var.prefix}-${var.container_name}-${random_string.name.result}"                     # The name of the container in your task definition
    container_port   = var.ecs_port                   # The port on which your container listens
  }

  launch_type = "FARGATE"
}

resource "aws_iam_role" "task_execution_role" {
  name = "TaskExecutionRole-${random_string.name.result}"  # Consistent role name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect    = "Allow"
        Sid       = ""
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.task_execution_role.name  # Use the correct reference
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_lb" "ecs_alb" {
  name               = "${var.prefix}-alb-${random_string.name.result}"
  internal           = false
  security_groups    = [aws_security_group.my_security_group.id]
  subnets            = [aws_subnet.dash_subnet.id,
                        aws_subnet.dash_subnet_2.id
                        ]
  load_balancer_type = "application"

  enable_deletion_protection      = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "my-alb"
  }
}

resource "aws_lb_target_group" "ecs_tg" {
 name        = "${var.prefix}-tg-${random_string.name.result}"
 port        = 80
 protocol    = "HTTP"
 target_type = "ip"
 vpc_id      = aws_vpc.my_vpc.id

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
}
}

resource "aws_lb_listener" "ecs_alb_listener" {
 load_balancer_arn = aws_lb.ecs_alb.arn
 port              = 80
 protocol          = "HTTP"

 default_action {
   type             = "forward"
   target_group_arn = aws_lb_target_group.ecs_tg.arn
 }
}







