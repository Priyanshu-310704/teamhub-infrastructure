
variable "project_name" {
  description = "Name prefix for TeamHub AWS resources"
  type        = string
  default     = "teamhub"
}

variable "vpc_cidr" {
  description = "CIDR range for the TeamHub VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.5.0/24", "10.0.6.0/24"]
}

variable "aws_region" {
  description = "AWS region for TeamHub infrastructure"
  type        = string
  default     = "ap-south-1"
}