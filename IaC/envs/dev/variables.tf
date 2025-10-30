variable "aws_region" {
    type = string
}

variable "vpc_cidr" {
    type = string
}
variable "project_name" {
    type = string
}
variable "az_count" {
    type = number
}
variable "public_subnet_cidrs"{
    type = list(string)
}
//private subnets for the app
variable "app_subnet_cidrs" {
    type = list(string)
}
//private subnet for the db
variable "data_subnet_cidrs" {
    type = list(string)
}
//
variable "internal_domain" {
    type = string
}
variable "db_username"{
    type = string
}
variable "db_password"{
    type = string
}
variable "db_name"{
    type = string
}