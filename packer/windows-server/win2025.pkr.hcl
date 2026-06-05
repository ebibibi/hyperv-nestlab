# Windows Server 2025 golden VHDX を Autounattend で無人ビルドする。
# 利用者が assets/iso/ に置いた ISO を入力に、sysprep 済み VHDX を出力する。
# バージョンは固定 (原則②)。Build-WindowsGolden.ps1 から呼ばれる。

packer {
  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "= 1.1.4"
    }
  }
}

variable "iso_path"         { type = string }
variable "output_directory" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}

source "hyperv-iso" "win2025" {
  iso_url      = var.iso_path
  iso_checksum = "none" # ローカル ISO。利用者配置物のため検証は images.yml 側で管理

  output_directory = var.output_directory
  vm_name          = "win2025-golden"
  generation       = 2
  enable_secure_boot = false # 無人インストール中は無効化 (完成後の L2 で必要なら有効化)
  cpus             = 4
  memory           = 4096
  disk_size        = 81920
  switch_name      = "Default Switch"

  # Autounattend.xml を CD として自動添付 (Windows setup が CD ルートから読む)
  cd_content = {
    "Autounattend.xml" = templatefile("${path.root}/Autounattend.xml", {
      admin_password = var.admin_password
    })
  }

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = "4h"

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "30m"
}

build {
  sources = ["source.hyperv-iso.win2025"]

  # 共通プロビジョニング (Windows Update 等はここに追加)
  provisioner "powershell" {
    inline = [
      "Write-Host 'golden image 共通プロビジョニング'",
      "Set-Service -Name wuauserv -StartupType Manual"
    ]
  }

  # sysprep で一般化 (展開先で固有化されるようにする)
  provisioner "powershell" {
    inline = [
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm"
    ]
  }
}
