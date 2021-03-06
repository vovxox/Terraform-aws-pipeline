#set variables list
#var.whitelist                
#var.prod_image_id               
#var.prod_instance_type    
#var.prod_desired_capacity    
#var.prod_max_size            
#var.prod_min_size 
#var.prod_access_key          
#var.prod_secret_key 

provider "aws" {
  access_key  = var.prod_access_key
  secret_key  = var.prod_secret_key
  region      = "us-east-1"
}

#test
module "vm_module" {
  source = "/Users/Caleb/Bigdatagit/Terraform-aws-pipeline/modules/vm"
  ami = "ami-2757f631"
  instancetype = "t2.micro"
  vmname = "myvm001"
}


#create s3 buckets
resource "aws_s3_bucket" "prod_web" {
  bucket      = "2randombucketname222222"
  acl         = "private"

  provisioner "local-exec" {
    command = "pip install requests && python apipull.py "
  }
  
  tags = {
    "Terraform" : "true"
  }
}

#uploading items to S3 data lake
resource "aws_s3_bucket_object" "prod_file_upload" {
  bucket = aws_s3_bucket.prod_web.id
  key    = "data.json"
  source = "./data.json"
  #etag line is for updates
  #etag = "${MD5(file(./data.json}"
}

#iam inline policy & assume role for lambda 
resource "aws_iam_role_policy" "lambda_policy" {
  name   = "lambda_policy"
  role   = aws_iam_role.lambda_role.id
  policy = "${file("iam/lambda-policy.json")}"
}

resource "aws_iam_role" "lambda_role" {
  name               = "lambda_role"
  assume_role_policy = "${file("iam/lambda-assume-policy.json")}"
}

#iam policy & assume role for glue

resource "aws_iam_role_policy" "glue_policy" {
  name   = "glue_policy"
  role   = aws_iam_role.glue_role.id
  policy = "${file("iam/lambda-policy.json")}"
}

resource "aws_iam_role" "glue_role" {
  name               = "glue-role"
  assume_role_policy = "${file("iam/glue-assume-policy.json")}"
}

#lambda function to do apipull 
resource "aws_lambda_function" "test_lambda" {
  filename         = "${local.lambda_zip_location}"
  function_name    = "lambdaapipull"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambdaapipull.hello"

 #this allows to refresh the lambda fuction code
  source_code_hash = "${filebase64sha256(local.lambda_zip_location)}"
  runtime          = "python3.7"

}

#creating a zip file/Archive a single file 
data "archive_file" "lambdaapipull" {
  type        = "zip"
  source_file = "lambdaapipull.py"
  output_path = local.lambda_zip_location
}

#have to make sure output_path & filename match
#to maintain use locals & use same value twice
locals {
  lambda_zip_location = "outputs/lamdaapipull.zip"
}

resource "aws_glue_classifier" "import-json" {
  name = "import-json-class"

  json_classifier {
    json_path = "s3://2randombucketname22222/"
  }
}

resource "aws_glue_crawler" "import-json-crawler" {
  database_name = aws_s3_bucket.prod_web.id
  name          = "import-json-crawler"
  role          = aws_iam_role.glue_role.arn
  #classifiers   = aws_glue_classifier.import-json.id

  s3_target {
    path = "s3://2randombucketname22222/"
  }
}

resource "aws_glue_job" "import-json-job" {
  name     = "import-json-job"
  role_arn = "${aws_iam_role.glue_role.arn}"

  command {
    script_location = "s3://aws-glue-scripts-468471399855-us-east-1/cloud_user"
  }
}

resource "aws_glue_connection" "import-json" {
  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:redshift://tf-redshift-cluster.crg5urli0qj7.us-east-1.redshift.amazonaws.com:5439/mydb"
    PASSWORD            = "Mustbe8characters"
    USERNAME            = "randomname"
  }

  name = "import-json-connection"

}

resource "aws_glue_trigger" "myjsonjob" {
  name     = "myjob"
  schedule = "cron(15 12 * * ? *)"
  type     = "SCHEDULED"

  actions {
    job_name = "${aws_glue_job.import-json-job.name}"
  }
}

#redshift cluster creation 
resource "aws_redshift_cluster" "default" {
  cluster_identifier = "tf-redshift-cluster"
  database_name      = "mydb"
  master_username    = "randomname"
  master_password    = "Mustbe8characters"
  node_type          = "dc1.large"
  cluster_type       = "single-node"
  final_snapshot_identifier = "false" 
}

#we can replicate 1 per az in our region 
resource "aws_default_subnet" "default_az1" {
  availability_zone   = "us-east-1a"

  tags = {
    "Terraform" : "true"
  }
}

resource "aws_default_vpc" "default" {}

resource "aws_default_subnet" "default_az2" {
  availability_zone = "us-east-1b"

  tags = {
    "Terraform" : "true"
  }
}

resource "aws_security_group" "prod_web" {
  name        = "prod_web"
  description = "Allow standard http and https ports inbound and everything outbound"

  ingress {
    from_port    = 80
    to_port      = 80
    
    protocol     = "tcp"
    cidr_blocks  = var.whitelist 
  }
  ingress {
    from_port    = 443
    to_port      = 443
    protocol     = "tcp"
    cidr_blocks  = var.whitelist 
  }
  egress {
    from_port    = 0
    to_port      = 0
    protocol     = "-1"
    cidr_blocks  = var.whitelist 
  }
  
  #tag identifies what was made by terraform in aws
  tags = {
    "Terraform" : "true"
  }
}

/*
resource "aws_instance" "prod_web" {
  count = 2

  ami           = "ami-2757f631"
  instance_type = "t2.micro"

  vpc_security_group_ids = [
    aws_security_group.prod_web.id
  ]
  tags = {
    "Terraform" : "true"
  }
}

#added for decoupling the ip addresses for autoscaling
resource "aws_eip_association" "prod_web" {
    instance_id   = aws_instance.prod_web[0].id
    allocation_id = aws_eip.prod_web.id 
}


#sets a static ip address
resource "aws_eip" "prod_web" {
    tags = {
    "Terraform" : "true"
  }
}
*/
resource "aws_elb" "prod_web" {
    name            = "prod-web"
    #here w/* want to pass list on instnaces for load balancing 
    #instances        = aws_instance.prod_web.*.id
    #here we want to pass array of our subnets
    subnets         = [aws_default_subnet.default_az1.id, aws_default_subnet.default_az2.id]
    security_groups = [aws_security_group.prod_web.id]

    listener {
      instance_port     = 80
      instance_protocol = "http"
      lb_port           = 80
      lb_protocol       = "http"
    }
    tags = {
    "Terraform" : "true"
  }
}

resource "aws_launch_template" "prod_web" {
  name_prefix   = "prod-web"
  image_id      = var.prod_image_id    
  instance_type = var.prod_instance_type 
  tags = {
    "Terraform" : "true"
  }
}

resource "aws_autoscaling_group" "prod_web" {
  availability_zones  = ["us-east-1a","us-east-1b"]
  vpc_zone_identifier = [aws_default_subnet.default_az1.id, aws_default_subnet.default_az2.id]
  desired_capacity    = var.prod_desired_capacity 
  max_size            = var.prod_max_size
  min_size            = var.prod_min_size

  launch_template {
    id      = aws_launch_template.prod_web.id
    version = "$Latest"
  }

  #tags->tag x= are different for autoscaling b/c using these tags to apply to any instance
  tag {
    key                 = "Terraform"
    value               = "true"
    propagate_at_launch = true
  }
}

#need an auto-scaling attachment resouce to attach autoscale group to elb
resource "aws_autoscaling_attachment" "prod_web" {
  autoscaling_group_name = aws_autoscaling_group.prod_web.id
  elb                    = aws_elb.prod_web.id
}

                   
