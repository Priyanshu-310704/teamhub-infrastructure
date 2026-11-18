
# ==========================================
# 1. JENKINS SECURITY GROUP
# ==========================================

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Security group for TeamHub Jenkins server"
  vpc_id      = aws_vpc.main.id

  # No inbound rules.
  # Jenkins will be accessed through AWS SSM.

  egress {
    description = "Allow outbound traffic for package downloads and integrations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-jenkins-sg"
  })
}


# ==========================================
# 2. JENKINS IAM ROLE
# ==========================================

resource "aws_iam_role" "jenkins_role" {
  name = "${var.project_name}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}


# Allow Jenkins EC2 to communicate with AWS Systems Manager
resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


# Attach IAM role to EC2 through an instance profile
resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins_role.name
}


# ==========================================
# 3. JENKINS EC2 INSTANCE
# ==========================================

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.app[1].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]

  iam_instance_profile        = aws_iam_instance_profile.jenkins_profile.name
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y java-21-amazon-corretto docker
    systemctl enable docker
    systemctl start docker
  EOF

  user_data_replace_on_change = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-jenkins-server"
    Role = "CI-CD"
  })

  depends_on = [
    aws_iam_role_policy_attachment.jenkins_ssm
  ]
}
