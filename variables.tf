variable "cluster_name" {
  description = "number of of the ECS cluster"
  type        = string
  default     = "simple-fargate"
}

variable "task_count" {
  description = "number of tasks to start"
  default     = 1
  type        = number
}