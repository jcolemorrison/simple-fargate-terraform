terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

# ECS Cluster
resource "aws_ecs_cluster" "cluster" {
  name = "${var.cluster_name}-cluster"
}

# Grab Default VPC
data "aws_vpc" "default" {
  default = true
}

# Use the default subnets
data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

# Security group enabling port 80 access
resource "aws_security_group" "lb" {
  name        = "${var.cluster_name}-lb-sg"
  description = "access to the application load balancer"

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security group for the ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.cluster_name}-ecs-tasks-sg"
  description = "allow inbound access from the ALB only"

  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    cidr_blocks     = ["0.0.0.0/0"]
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The Application Load Balancer
resource "aws_lb" "alb" {
  name               = "${var.cluster_name}-alb"
  subnets            = data.aws_subnet_ids.default.ids
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb.id]
}

# The Application Load Balancer's Port 80 Listener
resource "aws_lb_listener" "https_forward" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }
}

# Target group for the ECS Tasks to have their traffic routed to via ALB
resource "aws_lb_target_group" "target_group" {
  name        = "${var.cluster_name}-alb-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    healthy_threshold   = "3"
    interval            = "90"
    protocol            = "HTTP"
    matcher             = "200-299"
    timeout             = "20"
    path                = "/"
    unhealthy_threshold = "2"
  }
}

# IAM Role for the ECS Tasks
resource "aws_iam_role" "ecs_task_execution" {
  assume_role_policy  = data.aws_iam_policy_document.ecs_task_execution_assume_role_doc.json
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
}

data "aws_iam_policy_document" "ecs_task_execution_assume_role_doc" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    effect = "Allow"
  }
}

# Combine ./script.sh into a single line command for ECS Task definition
data "template_file" "template_json" {
  template = templatefile("${path.module}/task_definition.tpl.json", {
    script    = replace(file("${path.module}/script.sh"), "\n", " && ")
    logs_name = "${var.cluster_name}-logs"
  })
}

# Task definition for containers and other settings
resource "aws_ecs_task_definition" "task_definition" {
  cpu                      = "256"
  memory                   = "512"
  family                   = "${var.cluster_name}-task-definition"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  container_definitions    = data.template_file.template_json.rendered
}

# The service that pulls the task definitions and keeps it all alive
resource "aws_ecs_service" "service" {
  name            = "${var.cluster_name}-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task_definition.arn
  desired_count   = var.task_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets          = data.aws_subnet_ids.default.ids
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn
    container_name   = "nginx"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.https_forward, aws_iam_role.ecs_task_execution]
}

# The Cloud Watch Logs
resource "aws_cloudwatch_log_group" "simple_fargate_task_logs" {
  name = "${var.cluster_name}-logs"
}