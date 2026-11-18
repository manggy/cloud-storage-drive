mock_provider "aws" {}

variables {
  account_id        = "123456789012"
  region            = "us-east-2"
  availability_zone = "us-east-2a"
}

run "hosted_index_ingress_and_disk" {
  command = plan

  assert {
    condition = (
      length(aws_lightsail_instance_public_ports.browser_ssh.port_info) == 1 &&
      one(aws_lightsail_instance_public_ports.browser_ssh.port_info).from_port == 22 &&
      one(aws_lightsail_instance_public_ports.browser_ssh.port_info).to_port == 22 &&
      contains(one(aws_lightsail_instance_public_ports.browser_ssh.port_info).cidr_list_aliases, "lightsail-connect") &&
      aws_lightsail_disk.postgres.size_in_gb == 8
    )
    error_message = "Only browser SSH should be defined as public ingress and the index needs its own data disk."
  }
}
