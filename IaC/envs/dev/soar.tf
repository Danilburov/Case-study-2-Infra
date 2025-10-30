locals { project = "case-study-2" }

# Package lambdas from source each apply
data "archive_file" "collector_zip" {
  type        = "zip"
  source_dir  = "${path.module}/soar/collector_lamda"
  output_path = "${path.module}/soar/rule_collector_lambda.zip"
}
data "archive_file" "engine_zip" {
  type        = "zip"
  source_dir  = "${path.module}/soar/rule_engine_lambda"
  output_path = "${path.module}/soar/rule_engine_lambda.zip"
}

# SQS
resource "aws_sqs_queue" "events" {
  name                       = "${local.project}-soar-events"
  visibility_timeout_seconds = 60
}

# DynamoDB (action log)
resource "aws_dynamodb_table" "actions" {
  name         = "${local.project}-soar-actions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key = "id"
  range_key = "ts"
  attribute {
    name = "id"
     type = "S"
    }
  attribute {
    name = "ts"
    type = "N"
  }
}

# IAM
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
        type = "Service"
        identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "collector" {
  name               = "${local.project}-collector-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "collector_basic" {
  role       = aws_iam_role.collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_policy" "collector_sqs" {
  name   = "${local.project}-collector-sqs"
  policy = jsonencode({Version="2012-10-17",Statement=[{
    Effect="Allow",Action=["sqs:SendMessage"],Resource=aws_sqs_queue.events.arn
  }]})
}
resource "aws_iam_role_policy_attachment" "collector_attach" {
  role       = aws_iam_role.collector.name
  policy_arn = aws_iam_policy.collector_sqs.arn
}

resource "aws_iam_role" "engine" {
  name               = "${local.project}-engine-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "engine_basic" {
  role       = aws_iam_role.engine.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_policy" "engine_actions" {
  name   = "${local.project}-engine-actions"
  policy = jsonencode({Version="2012-10-17",Statement=[
    {Effect="Allow",Action=["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],Resource=aws_sqs_queue.events.arn},
    {Effect="Allow",Action=["dynamodb:PutItem"],Resource=aws_dynamodb_table.actions.arn},
    {Effect="Allow",Action=["ses:SendEmail","ses:SendRawEmail"],Resource="*"},
    {Effect="Allow",Action=["cloudwatch:PutMetricData"],Resource="*",Condition={"StringEquals":{"cloudwatch:namespace":"SOAR"}}}
  ]})
}
resource "aws_iam_role_policy_attachment" "engine_attach" {
  role       = aws_iam_role.engine.name
  policy_arn = aws_iam_policy.engine_actions.arn
}

# Lambdas
resource "aws_lambda_function" "collector" {
  function_name    = "${local.project}-collector"
  role             = aws_iam_role.collector.arn
  runtime          = "python3.11"
  handler          = "app.handler"
  filename         = data.archive_file.collector_zip.output_path
  source_code_hash = data.archive_file.collector_zip.output_base64sha256
  environment { variables = { QUEUE_URL = aws_sqs_queue.events.id } }
}

resource "aws_lambda_function" "engine" {
  function_name    = "${local.project}-rule-engine"
  role             = aws_iam_role.engine.arn
  runtime          = "python3.11"
  handler          = "app.handler"
  filename         = data.archive_file.engine_zip.output_path
  source_code_hash = data.archive_file.engine_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ACTIONS_TABLE = aws_dynamodb_table.actions.name
      SES_FROM      = var.ses_from_email
      SES_TO        = var.ses_to_email
    }
  }
}


resource "aws_lambda_event_source_mapping" "engine_from_sqs" {
  event_source_arn = aws_sqs_queue.events.arn
  function_name    = aws_lambda_function.engine.arn
  batch_size       = 5
}

# Internal ALB (VPN-only) -> Lambda collector
resource "aws_security_group" "alb_internal" {
  name   = "${local.project}-alb-internal-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port=80 
    to_port=80
    protocol="tcp" 
    cidr_blocks=["10.100.0.0/22"]
    }
  egress  {
    from_port=0
    to_port=0
    protocol="-1"
    cidr_blocks=["0.0.0.0/0"]
    }
}

resource "aws_lb" "soar_internal" {
  name               = "${local.project}-soar-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_internal.id]
  subnets            = [aws_subnet.app[0].id, aws_subnet.app[1].id]
}

resource "aws_lb_target_group" "collector" {
  name        = "${local.project}-collector-tg"
  target_type = "lambda"
}

# allow ALB to invoke Lambda (must exist before attachment)
resource "aws_lambda_permission" "alb_invoke_collector" {
  statement_id  = "AllowFromALB"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.collector.arn
}

# register lambda as target – wait for permission
resource "aws_lb_target_group_attachment" "collector_attach" {
  target_group_arn = aws_lb_target_group.collector.arn
  target_id        = aws_lambda_function.collector.arn
  depends_on       = [aws_lambda_permission.alb_invoke_collector]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.soar_internal.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.collector.arn
    }
}

data "aws_region" "current" {}

resource "aws_cloudwatch_dashboard" "soar" {
  dashboard_name = "${local.project}-soar"
  dashboard_body = jsonencode({
    widgets = [
      {
        "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
        "properties": {
          "title": "SOAR - Events Processed",
          "region": data.aws_region.current.name,
          "view": "timeSeries",
          "stat": "Sum",
          "period": 60,
          "metrics": [
            ["SOAR","EventsProcessed"]
          ]
        }
      },
      {
        "type": "metric", "x": 0, "y": 6, "width": 12, "height": 6,
        "properties": {
          "title": "SOAR - Actions Success/Failure",
          "region": data.aws_region.current.name,
          "view": "timeSeries",
          "stat": "Sum",
          "period": 60,
          "metrics": [
            ["SOAR","ActionSuccess","Action","email"],
            ["SOAR","ActionFailure","Action","email"],
            ["SOAR","ActionSuccess","Action","log"],
            ["SOAR","ActionFailure","Action","log"]
          ]
        }
      }
    ]
  })
}


output "soar_internal_alb_dns" { value = aws_lb.soar_internal.dns_name }
