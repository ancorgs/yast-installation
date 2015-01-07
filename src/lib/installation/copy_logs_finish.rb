# ------------------------------------------------------------------------------
# Copyright (c) 2006-2015 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------

require "installation/finish_client"

module Installation
  class CopyLogsFinish < ::Installation::FinishClient
    include Yast::I18n

    def initialize
      Yast.import "UI"

      textdomain "installation"

      Yast.import "Directory"
      Yast.include self, "installation/misc.rb"
    end

    def steps
      1
    end

    def title
      _("Copying log files to installed system...")
    end

    def modes
      [:installation, :live_installation, :update, :autoinst]
    end

    def write
      @log_files = Yast::Convert.convert(
        Yast::WFM.Read(path(".local.dir"), Yast::Directory.logdir),
        :from => "any",
        :to   => "list <string>"
      )

      Yast::Builtins.foreach(@log_files) do |file|
        log.debug "Processing file #{file}"

        if file == "y2log" || Yast::Builtins.regexpmatch(file, "^y2log-[0-9]+$")
          # Prepare y2log, y2log-* for log rotation

          target_no = 1

          if Yast::Ops.greater_than(Yast::Builtins.size(file), Yast::Builtins.size("y2log-"))
            target_no = Yast::Ops.add(
              1,
              Yast::Builtins.tointeger(
                Yast::Builtins.substring(file, Builtins.size("y2log-"), 5)
              )
            )
          end

          target_basename = Yast::Builtins.sformat("y2log-%1", target_no)
          InjectRenamedFile(Yast::Directory.logdir, file, target_basename)

          compress_cmd = Yast::Builtins.sformat(
            "gzip %1/%2/%3",
            Yast::Installation.destdir,
            Yast::Directory.logdir,
            target_basename
          )
          log.debug "Compress command: #{compress_cmd}"
          Yast::WFM.Execute(path(".local.bash"), compress_cmd)
        elsif Yast::Builtins.regexpmatch(file, "^y2log-[0-9]+\\.gz$")
          target_no = Yast::Ops.add(
            1,
            Yast::Builtins.tointeger(
              Yast::Builtins.regexpsub(file, "y2log-([0-9]+)\\.gz", "\\1")
            )
          )
          InjectRenamedFile(
            Yast::Directory.logdir,
            file,
            Yast::Builtins.sformat("y2log-%1.gz", target_no)
          )
        elsif file == "zypp.log"
          # Save zypp.log from the inst-sys
          InjectRenamedFile(Yast::Directory.logdir, file, "zypp.log-1") # not y2log, y2log-*
        else
          InjectFile(Yast::Ops.add(Yast::Ops.add(Yast::Directory.logdir, "/"), file))
        end
      end

      copy_cmd = "/bin/cp /var/log/pbl.log '#{Yast::Installation.destdir}/#{Yast::Directory.logdir}/pbl-instsys.log'"
      log.debug "Copy command: #{copy_cmd}"
      Yast::WFM.Execute(path(".local.bash"), copy_cmd)

      nil
    end
  end
end
