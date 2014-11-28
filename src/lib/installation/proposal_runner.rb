# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2006-2012 Novell, Inc. All Rights Reserved.
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

require "yast"

module Installation

  # Create and display reasonable proposal for basic
  # installation and call sub-workflows as required
  # on user request.
  #
  # See {Installation::ProposalClient} from yast2 for API overview
  class ProposalRunner
    include Yast::I18n
    include Yast::UIShortcuts
    include Yast::Logger

    def self.run
      new.run
    end

    def initialize
    end

    def run
      Yast.import "Pkg"
      Yast.import "UI"
      textdomain "installation"

      Yast.import "Label"
      Yast.import "Mode"
      Yast.import "Stage"
      Yast.import "AutoinstConfig"
      Yast.import "Wizard"
      Yast.import "HTML"
      Yast.import "Popup"
      Yast.import "Language"
      Yast.import "GetInstArgs"
      Yast.import "String"

      # values used in defined functions

      @proposal_properties = {}
      @submodules = []
      @submodules_presentation = []
      @mod2tab = {} # module -> tab it is in
      @display_only_modules = [] # modules which do not have propose, but only summary
      @current_tab = 0 # ID of current tab
      @has_tab = false # true if is tabbed proposal
      @html = {} # proposals of all modules - HTML part
      @present_only = []
      @locked_modules = []
      @titles = []
      @submod2id = {}
      @id2submod = {}
      @link2submod = {}
      @have_blocker = false

      # FATE #301151: Allow YaST proposals to have help texts
      @submodule_helps = {}

      @proposal_result = nil

      # skip if not interactive mode.
      if !Yast::AutoinstConfig.Confirm && (Yast::Mode.autoinst || Yast::Mode.autoupgrade)
        return :auto
      end

      # BNC #463567
      @submods_already_called = []



      #-----------------------------------------------------------------------
      #				    main()
      #-----------------------------------------------------------------------



      #
      # Create dialog
      #
      # This is done as early as possible for instant feedback, even though the
      # menu is still empty. Fortunately enough, nobody will notice this since
      # we also disable it until everything in there is known. This is to be
      # done before even the submodule descriptions are known since they usually
      # are in separate YCP files that liberally import other YCP modules which
      # in turn takes considerable time for the module constructors.
      #

      Yast::Builtins.y2milestone("Installation step #2")
      @proposal_mode = Yast::GetInstArgs.proposal

      if Yast::ProductControl.GetDisabledProposals.include?(@proposal_mode)
        return :auto
      end

      @proposal_properties = Yast::ProductControl.getProposalProperties(
        Yast::Stage.stage,
        Yast::Mode.mode,
        @proposal_mode
      )
      build_dialog

      #
      # Get submodule descriptions
      #
      @proposal_result = load_matching_submodules_list
      return :abort if @proposal_result == :abort

      Yast::UI.ChangeWidget(Id(:menu_dummy), :Enabled, false) if Yast::UI.TextMode
      richtext_busy_cursor(Id(:proposal))

      # The "next" button is disabled via Wizard::SetContents() until everything is set up allright
      Yast::Wizard.EnableNextButton
      Yast::Wizard.EnableAbortButton

      return :auto if !get_submod_descriptions_and_build_menu


      #
      # Make the initial proposal
      #
      make_proposal(false, false)

      #
      # Input loop
      #

      @input = nil

      # Set keyboard focus to the [Install] / [Update] or [Next] button
      Yast::Wizard.SetFocusToNextButton

      while true
        richtext_normal_cursor(Id(:proposal))
        # bnc #431567
        # Some proposal module can change it while called
        SetNextButton()

        @input = Yast::UI.UserInput

        return :next if @input == :accept
        return :abort if @input == :cancel

        log.info "Proposal - UserInput: '#{@input}'"
        richtext_busy_cursor(Id(:proposal))

        # check for tab

        if @input.is_a?(::Integer)
          @current_tab = @input
          load_matching_submodules_list
          @proposal = ""
          @submodules_presentation.each do |mod|
            @proposal << @html[mod] || ""
          end
          display_proposal(@proposal)
          get_submod_descriptions_and_build_menu
        end

        case @input
        when ::String #hyperlink
          # get module for hyperlink id
          @submod = @id2submod[@input] || ""

          if @submod == ""
            # also try hyperlinks
            @submod = @link2submod[@input] || ""
          end

          if @submod != ""
            # if submod is not the same as input id, provide id to the module
            @additional_info = { "has_next" => false }

            @additional_info["chosen_id"] = @input if @submod != @input

            # Call AskUser() function.
            # This will trigger another call to make_proposal() internally.
            @input = submod_ask_user(@submod, @additional_info)

            # The workflow_sequence doesn't get handled as a workflow sequence
            # so we have to do this special case here. Kind of broken.
            return :finish if @input == :finish
          end
        when :finish
          return :finish
        when :abort
          if Yast::Stage.initial
            return :abort if Yast::Popup.ConfirmAbort(:painless)
          else
            return :abort if Yast::Popup.ConfirmAbort(:incomplete)
          end
        when :reset_to_defaults
            next unless Yast::Popup.ContinueCancel(
              # question in a popup box
              _("Really reset everything to default values?") + "\n" +
                # explain consequences of a decision
                _("You will lose all changes.")
            )
          make_proposal(true, false) # force_reset
        when :export_config
          path = Yast::UI.AskForSaveFileName("/", "*.xml", _("Location of Stored Configuration"))
          next unless path

          # force write, so it always write profile even if user do not want
          # to store profile after installation
          Yast::WFM.CallFunction("clone_proposal", ["Write", "force" => true, "target_path" => path])
          if !File.exists?(path)
            raise _("Failed to store configuration. Details can be found in log.")
          end
        when :skip, :dontskip
          if Yast::UI.QueryWidget(Id(:skip), :Value)
            # User doesn't want to use any of the settings
            Yast::UI.ChangeWidget(
              Id(:proposal),
              :Value,
              Yast::HTML.Newlines(3) +
                # message show when user has disabled the configuration
                Yast::HTML.Para(_("Skipping configuration upon user request"))
            )
            Yast::UI.ChangeWidget(Id(:menu), :Enabled, false)
          else
            # User changed his mind and wants the settings back - recreate them
            make_proposal(false, false)
            Yast::UI.ChangeWidget(Id(:menu), :Enabled, true)
          end
        when :next
          @skip = Yast::UI.WidgetExists(Id(:skip)) ?
            Yast::Convert.to_boolean(Yast::UI.QueryWidget(Id(:skip), :Value)) :
            true
          @skip_blocker = Yast::UI.WidgetExists(Id(:skip)) && @skip
          if @have_blocker && !@skip_blocker
            # error message is a popup
            Yast::Popup.Error(
              _(
                "The proposal contains an error that must be\nresolved before continuing.\n"
              )
            )
            next
          end

          if Yast::Stage.stage == "initial"
            @input = Yast::WFM.CallFunction("inst_doit", [])
          # bugzilla #219097, #221571, yast2-update on running system
          elsif Yast::Stage.stage == "normal" && Yast::Mode.update
            if !confirmInstallation
              log.info "Update not confirmed, returning back..."
              @input = nil
            end
          end

          if @input == :next
            # anything that needs to be done before
            # real installation starts

            write_settings if !@skip

            return :next
          end
        when :back
          Yast::Wizard.SetNextButton(:next, Yast::Label.NextButton) if Yast::Stage.initial
          return :back
        end
      end # while input loop

      nil
    end

  private

    # Display preformatted proposal in the RichText widget
    #
    # @param [String] proposal human readable proposal preformatted in HTML
    #
    def display_proposal(proposal)
      if Yast::UI.WidgetExists(Id(:proposal))
        Yast::UI.ChangeWidget(Id(:proposal), :Value, proposal)
      else
        Yast::Builtins.y2error(-1, "Widget `proposal does not exist")
      end

      nil
    end

    def CheckAndCloseWindowsLeft
      if !Yast::UI.WidgetExists(Id(:proposal))
        Yast::Builtins.y2error(-1, "Widget `proposal is not active!!!")
        log.info "--- Current widget tree ---"
        Yast::UI.DumpWidgetTree
        log.info "--- Current widget tree ---"
      end

      nil
    end


    # Call a submodule's MakeProposal() function.
    #
    # @param [String] submodule	name of the submodule's proposal dispatcher
    # @param [Boolean] force_reset	discard any existing (cached) proposal
    # @param [Boolean] language_changed	installation language changed since last call
    # @return proposal_map	see proposal-API.txt
    #

    def submod_make_proposal(submodule, force_reset, language_changed)
      Yast::UI.BusyCursor

      proposal = Yast::WFM.CallFunction(
        submodule,
        [
          "MakeProposal",
          {
            "force_reset"      => force_reset,
            "language_changed" => language_changed
          }
        ]
      )
      log.debug "#{submodule} MakeProposal() returns #{proposal}"

      # There might be some UI layers left
      # we need to close them
      CheckAndCloseWindowsLeft()

      Yast::UI.NormalCursor

      deep_copy(proposal)
    end


    # Call a submodule's AskUser() function.
    #
    # @param [String] submodule	name of the submodule's proposal dispatcher
    # @param  has_next		force a "next" button even if the submodule would otherwise rename it
    # @return workflow_sequence see proposal-API.txt
    #
    def submod_ask_user(submodule, additional_info)
      # Call the AskUser() function
      ask_user_result = Yast::WFM.CallFunction(submodule, ["AskUser", additional_info])

      workflow_sequence = ask_user_result["workflow_sequence"] || :next
      language_changed = ask_user_result.fetch("language_changed", false)
      mode_changed = ask_user_result.fetch("mode_changed", false)
      rootpart_changed = ask_user_result.fetch("rootpart_changed", false)

      if ![:cancel, :back, :abort, :finish].include?(workflow_sequence)
        if language_changed
          retranslate_proposal_dialog
          Yast::Pkg.SetTextLocale(Yast::Language.language)
          Yast::Pkg.SetPackageLocale(Yast::Language.language)
          Yast::Pkg.SetAdditionalLocales([Yast::Language.language])
        end

        if mode_changed
          Yast::Wizard.SetHelpText(help_text)

          build_dialog
          load_matching_submodules_list
          if !get_submod_descriptions_and_build_menu
            log.error "i'm in dutch"
          end
        end

        # Make a new proposal based on those user changes
        make_proposal(false, language_changed)
      end

      # There might be some UI layers left
      # we need to close them
      CheckAndCloseWindowsLeft()

      workflow_sequence
    end


    # Call a submodule's Description() function.
    #
    # @param [String] submodule	name of the submodule's proposal dispatcher or nil if no such module
    # @return description_map	see proposal-API.txt
    #

    def submod_description(submodule)
      Yast::UI.BusyCursor

      description = Yast::WFM.CallFunction(submodule, ["Description", {}])

      # There might be some UI layers left
      # we need to close them
      CheckAndCloseWindowsLeft()

      Yast::UI.NormalCursor

      description
    end

    def SubmoduleHelp(prop_map, submod)
      return unless prop_map.value["help"]

      use_this_help = false
      # using tabs
      if @mod2tab[submod.value]
        # visible in the current tab
        if @mod2tab[submod.value] == @current_tab
          use_this_help = true
        end
      # not using tabs
      else
        use_this_help = true
      end

      if use_this_help
        log.info "Submodule '#{submod.value}' has it's own help"
        own_help = prop_map.value["help"]

        if own_help.empty?
          log.info "Skipping empty help"
        else
          @submodule_helps[submod.value] = prop_map.value["help"]
        end
      end
    end
    def make_proposal(force_reset, language_changed)
      tab_to_switch = 999
      current_tab_affected = false
      no = 0
      prop_map = {}
      skip_the_rest = false
      @have_blocker = false

      @link2submod = {}

      Yast::UI.ReplaceWidget(
        Id("inst_proposal_progress"),
        ProgressBar(
          Id("pb_ip"),
          "",
          2 * @submodules.size,
          0
        )
      )
      submodule_nr = 0

      @html = {}
      @submodules.each do |submod|
        title = @titles[no] || _("ERROR: Missing Title")
        if !Yast::Builtins.contains(@locked_modules, submod)
          heading = Yast::Builtins.issubstring(Yast::Ops.get_string(@titles, no, ""), "<a") ?
            title :
            Yast::HTML.Link(
              title,
              Yast::Ops.get_string(@submod2id, submod, "")
            )

          # heading in proposal, in case the module doesn't create one
          prop = Yast::HTML.Heading(heading)
        else
          prop = Yast::HTML.Heading(title)
        end
        # BNC #463567
        # Submod already called
        if @submods_already_called.include?(submod)
          # busy message
          message = _("Adapting the proposal to the current settings...")
        # First run
        else
          # busy message;
          message = _("Analyzing your system...")
          @submods_already_called = Yast::Builtins.add(
            @submods_already_called,
            submod
          )
        end
        @html[submod] = prop + Yast::HTML.Para(message)
        no += 1
      end

      no = 0

      Yast::Wizard.DisableNextButton
      Yast::UI.BusyCursor

      @submodule_helps = {}

      log.debug "Submodules list before execution: #{@submodules}"
      Yast::Builtins.foreach(@submodules) do |submod|
        submodule_nr += 1
        Yast::UI.ChangeWidget(Id("pb_ip"), :Value, submodule_nr)
        prop = ""
        if !skip_the_rest
          if !Yast::Builtins.contains(@locked_modules, submod)
            heading = Yast::Builtins.issubstring(
              Yast::Ops.get_string(@titles, no, ""),
              "<a"
            ) ?
              Yast::Ops.get_locale(@titles, no, _("ERROR: Missing Title")) :
              Yast::HTML.Link(
                Yast::Ops.get_locale(@titles, no, _("ERROR: Missing Title")),
                Yast::Ops.get_string(@submod2id, submod, "")
              )

            # heading in proposal, in case the module doesn't create one
            prop << Yast::HTML.Heading(heading)
          else
            prop << Yast::HTML.Heading( @titles[no] || _("ERROR: Missing Title"))
          end

          prop_map = submod_make_proposal(submod, force_reset, language_changed)
          prop_map_ref = arg_ref(prop_map)
          submod_ref = arg_ref(submod)
          SubmoduleHelp(prop_map_ref, submod_ref)
          prop_map = prop_map_ref.value
          submod = submod_ref.value

          # check if it is needed to switch to another tab
          # because of an error
          if Yast::Builtins.haskey(@mod2tab, submod)
            log.info "Mod2Tab: '#{@mod2tab[submod]}'"
            warn_level = prop_map["warning_level"] || :ok
            if [:blocker, :fatal, :error].include?(warn_level)
              # bugzilla #237291
              # always switch to more detailed tab only
              # value 999 means to keep current tab, in case of error,
              # tab must be switched (bnc #441434)
              if @mod2tab[submod] > tab_to_switch ||
                  tab_to_switch == 999
                tab_to_switch = @mod2tab[submod]
              end
              if @mod2tab[submod] == @current_tab
                current_tab_affected = true
              end
            end
          end

          # update link map
          if prop_map["links"]
            prop_map["links"].each do |link|
              @link2submod[link] = submod
            end
          end
        end
        if prop_map["language_changed"] && !skip_the_rest
          skip_the_rest = true
          retranslate_proposal_dialog
          make_proposal(force_reset, true)
        end
        if !skip_the_rest
          prop << format_sub_proposal(prop_map)

          @html[submod] = prop

          # now do the complete html
          proposal = ""
          Yast::Builtins.foreach(@submodules_presentation) do |mod|
            proposal << @html[mod]
          end
          display_proposal(proposal)

          # display_proposal( prop );
          no += 1
        end
        if prop_map["warning_level"] == :fatal
          skip_the_rest = true
        end
        submodule_nr += 1
        Yast::UI.ChangeWidget(Id("pb_ip"), :Value, submodule_nr)
      end

      # FATE #301151: Allow YaST proposals to have help texts
      Yast::Wizard.SetHelpText(help_text) unless @submodule_helps.empty?

      if @has_tab && Yast::Ops.less_than(tab_to_switch, 999) && !current_tab_affected
        # FIXME copy-paste from event loop (but for last 2 lines)
        @current_tab = tab_to_switch
        load_matching_submodules_list
        proposal = ""
        Yast::Builtins.foreach(@submodules_presentation) do |mod|
          proposal = Yast::Ops.add(proposal, Yast::Ops.get(@html, mod, ""))
        end
        display_proposal(proposal)
        get_submod_descriptions_and_build_menu
        log.info "Switching to tab '#{@current_tab}'"
        if Yast::UI.HasSpecialWidget(:DumbTab)
          if Yast::UI.WidgetExists(:_cwm_tab)
            Yast::UI.ChangeWidget(Id(:_cwm_tab), :CurrentItem, @current_tab)
          else
            log.warn "Widget with id #{:_cwm_tab} does not exist!"
          end
        end
      end

      # now do the display-only proposals

      Yast::UI.ReplaceWidget(Id("inst_proposal_progress"), Empty())
      Yast::Wizard.EnableNextButton
      Yast::UI.NormalCursor

      nil
    end
    def format_sub_proposal(prop)
      prop = deep_copy(prop)
      html = ""
      warning = prop["warning"] || ""

      if !warning.empty?
        level = prop["warning_level"] || :warning

        case level
        when :notice
          warning = Yast::HTML.Bold(warning)
        when :warning
          warning = Yast::HTML.Colorize(warning, "red")
        when :error
          warning = Yast::HTML.Colorize(warning, "red")
        when :blocker, :fatal
          @have_blocker = true
          warning = Yast::HTML.Colorize(warning, "red")
        end

        html << Yast::HTML.Para(warning)
      end

      preformatted_prop = prop["preformatted_proposal"] || ""

      if preformatted_prop.empty?
        # fallback proposal, means usually an internal error
        raw_prop = prop["raw_proposal"] || [_("ERROR: No proposal")]
        html << Yast::HTML.List(raw_prop)
      else
        html << preformatted_prop
      end

      html
    end

    # Call a submodule's Write() function.
    #
    # @param [String] submodule	name of the submodule's proposal dispatcher
    # @return success		true if Write() was successful of if there is no Write() function
    #
    def submod_write_settings(submodule)
      result = Yast::WFM.CallFunction(submodule, ["Write", {}]) || {}

      result.fetch("success", true)
    end

    # Call each submodule's "Write()" function to let it write its settings,
    # i.e. the settings effective.
    #
    def write_settings
      success = true

      Yast::Builtins.foreach(@submodules) do |submod|
        submod_success = submod_write_settings(submod)
        submod_success = true if submod_success == nil
        if !submod_success
          log.error "Write() failed for submodule #{submod}"
        end
        success = success && submod_success
      end

      if !success
        log.error "Write() failed for one or more submodules"

        # Submodules handle their own error reporting
        # text for a message box
        Yast::Popup.TimedMessage(_("Configuration saved.\nThere were errors."), 3)
      end

      nil
    end


    # Force a RichText widget to use the busy cursor
    #
    # @param [Object] widget_id  ID  of the widget, e.g. `id(`proposal)
    #
    def richtext_busy_cursor(widget_id)
      Yast::UI.ChangeWidget(widget_id, :Enabled, false)

      nil
    end


    # Switch a RichText widget back to use the normal cursor
    #
    # @param [Object] widget_id  ID  of the widget, e.g. `id(`proposal)
    #
    def richtext_normal_cursor(widget_id)
      Yast::UI.ChangeWidget(widget_id, :Enabled, true)

      nil
    end
    def retranslate_proposal_dialog
      log.debug "Retranslating proposal dialog"

      build_dialog
      Yast::ProductControl.RetranslateWizardSteps
      Yast::Wizard.RetranslateButtons
      get_submod_descriptions_and_build_menu

      nil
    end
    def load_matching_submodules_list
      modules = []

      modules = Yast::ProductControl.getProposals(
        Yast::Stage.stage,
        Yast::Mode.mode,
        @proposal_mode
      )
      if modules == nil
        log.error "Error loading proposals"
        return :abort
      end

      @locked_modules = Yast::ProductControl.getLockedProposals(
        Yast::Stage.stage,
        Yast::Mode.mode,
        @proposal_mode
      )

      Yast::Builtins.y2milestone(
        "getting proposals for stage: \"%1\" mode: \"%2\" proposal type: \"%3\"",
        Yast::Stage.stage,
        Yast::Mode.mode,
        @proposal_mode
      )

      @proposal_properties = Yast::ProductControl.getProposalProperties(
        Yast::Stage.stage,
        Yast::Mode.mode,
        @proposal_mode
      )

      if modules.empty?
        log.error "No proposals available"
        return :abort
      end

      # in normal mode we don't want to switch between installation and update
      modules = Yast::Builtins.filter(modules) do |v|
        Yast::Ops.get_string(v, 0, "") != "mode_proposal"
      end if Yast::Mode.normal

      # now create the list of modules and order of modules for presentation
      @submodules = modulesmap { |mod| mod[0] || "" }

      log.info "Execution order: #{@submodules}"

      if @has_tab
        log.info "Proposal uses tabs"
        data = Yast::ProductControl.getProposalProperties(
          Yast::Stage.stage,
          Yast::Mode.mode,
          @proposal_mode
        )
        @submodules_presentation = Yast::Ops.get_list(
          data,
          ["proposal_tabs", @current_tab, "proposal_modules"],
          []
        )
        # All proposal file names end with _proposal
        @submodules_presentation = Yast::Builtins.maplist(@submodules_presentation) do |m|
          m += "_proposal" unless m.include?("_proposal")
          m
        end
        index = -1
        @mod2tab = {}
        tmp_all_submods = Yast::Builtins.maplist(data["proposal_tabs"] || []) do |tab|
          index += 1
          Yast::Builtins.foreach(Yast::Ops.get_list(tab, "proposal_modules", [])) do |m|
            m += "_proposal" unless m.include?("_proposal")
            if index < @mod2tab[m]
              @mod2tab[m] = index
            end
          end
          tab["proposal_modules"] || []
        end

        all_submods = Yast::Builtins.flatten(tmp_all_submods)
        all_submods = Yast::Builtins.maplist(all_submods) do |m|
          m += "_proposal" unless m.include?("_proposal")
          m
        end
        @display_only_modules = Yast::Builtins.filter(all_submods) do |m|
          !Yast::Builtins.contains(@submodules, m)
        end
        @submodules = @submodules + @display_only_modules
        p = Yast::AutoinstConfig.getProposalList
        @submodules_presentation = Yast::Builtins.filter(@submodules_presentation) do |v|
          Yast::Builtins.contains(p, v) || p == []
        end
      else
        log.info "Proposal doesn't use tabs"
        # sort modules according to presentation ordering
        modules.sort_by! { |mod| mod[1] || 50 }

        # setup the list
        @submodules_presentation = modules.map do |mod|
          mod[0] || ""
        end

        p = Yast::AutoinstConfig.getProposalList

        if p != nil && p != []
          # array intersection
          @submodules_presentation = @submodules_presentation & v
        end
      end

      log.info "Presentation order: #{@submodules_presentation}"
      log.info "Execution order: #{@submodules}"

      nil
    end


    # Find out if the target machine has a network card.
    # @return true if a network card is found, false otherwise
    #
    def have_network_card
      # Maybe obsolete
      return true if Yast::Mode.test

      !Yast::SCR.Read(Yast::Path.new(".probe.netcard")).empty?
    end

    def build_dialog
      # headline for installation proposal

      headline = @proposal_properties["label"] || ""


      log.info "headline: #{headline}"

      if headline == ""
        # dialog headline
        headline = _("Installation Overview")
      else
        headline = Yast::Builtins.dgettext(
          Yast::ProductControl.getProposalTextDomain,
          headline
        )
      end

      # icon for installation proposal
      icon = ""

      # radiobuttons
      skip_buttons = RadioButtonGroup(
        VBox(
          VSpacing(1),
          Left(
            RadioButton(
              Id(:skip),
              Opt(:notify),
              # Check box: Skip all the configurations in this dialog -
              # do this later manually or not at all
              # Translators: About 40 characters max,
              # use newlines for longer translations.
              # radio button
              _("&Skip Configuration"),
              false
            )
          ),
          Left(
            RadioButton(
              Id(:dontskip),
              Opt(:notify),
              # radio button
              _("&Use Following Configuration"),
              true
            )
          ),
          VSpacing(1)
        )
      )

      if Yast::UI.TextMode()
        change_point = ReplacePoint(
            Id(:rep_menu),
            # menu button
            MenuButton(Id(:menu_dummy), _("&Yast::Change..."), [Item(Id(:dummy), "")])
          )
      else
        change_point = PushButton(
            Id(:export_config),
            # menu button
            _("&Export Configuration")
          )
      end

      # change menu
      menu_box = VBox(
        HBox(
          HStretch(),
          change_point,
          HStretch()
        ),
        ReplacePoint(Id("inst_proposal_progress"), Empty())
      )

      vbox = nil

      enable_skip = true
      if Yast::Builtins.haskey(@proposal_properties, "enable_skip")
        enable_skip = Yast::Ops.get_string(@proposal_properties, "enable_skip", "yes") == "yes"
      else
        if @proposal_mode == "initial" || @proposal_mode == "uml"
          enable_skip = false
        else
          enable_skip = true
        end
      end
      rt = RichText(
        Id(:proposal),
        Yast::HTML.Newlines(3) +
        # Initial contents of proposal subwindow while proposals are calculated
          Yast::HTML.Para(_("Analyzing your system..."))
      )
      data = Yast::ProductControl.getProposalProperties(
        Yast::Stage.stage,
        Yast::Mode.mode,
        @proposal_mode
      )
      if Yast::Builtins.haskey(data, "proposal_tabs")
        @has_tab = true
        index = -1
        tabs = data["proposal_tabs"]
        tab_ids = Yast::Builtins.maplist(tabs) do |tab|
          index += 1
        end
        if Yast::UI.HasSpecialWidget(:DumbTab)
          panes = Yast::Builtins.maplist(tab_ids) do |t|
            label = Yast::Ops.get_string(tabs, [t, "label"], "Tab")
            Item(Id(t), label, t == 0)
          end
          rt = DumbTab(Id(:_cwm_tab), panes, rt)
        else
          tabbar = HBox()
          Yast::Builtins.foreach(tab_ids) do |t|
            label = Yast::Ops.get_string(tabs, [t, "label"], "Tab")
            tabbar = Yast::Builtins.add(tabbar, PushButton(Id(t), label))
          end
          rt = VBox(Left(tabbar), Frame("", rt))
        end
      else
        @has_tab = false
      end
      if !enable_skip
        vbox = VBox(
          # Help message between headline and installation proposal / settings summary.
          # May contain newlines, but don't make it very much longer than the original.
          Left(
            Label(
              if Yast::UI.TextMode()
                _(
                  "Click a headline to make changes or use the \"Yast::Change...\" menu below."
                )
              else
                _(
                  "Click a headline to make changes."
                )
              end
            )
          ),
          rt,
          menu_box
        )
      else
        vbox = VBox(skip_buttons, HBox(HSpacing(4), rt), menu_box)
      end

      Yast::Wizard.SetContents(
        headline, # have_next_button
        vbox,
        help_text,
        Yast::GetInstArgs.enable_back, # have_back_button
        false
      )
      set_icon
      if Yast::UI.HasSpecialWidget(:DumbTab)
        if Yast::UI.WidgetExists(:_cwm_tab)
          Yast::UI.ChangeWidget(Id(:_cwm_tab), :CurrentItem, @current_tab)
        else
          Yast::Builtins.y2milestone("Not using CWM tabs...")
        end
      end

      nil
    end

    def get_submod_descriptions_and_build_menu
      menu_list = []
      new_submodules = []
      no = 1
      @titles = []
      descriptions = {}

      @submodules.each do |submod|
        description = submod_description(submod)
        if description.nil?
          log.info "Submodule #{submod} not available (not installed?)"
        else
          if !description.empty?
            description["no"] = no
            descriptions[submod] = description
            new_submodules << submod
            title = description["rich_text_title"] ||
                description["rich_text_raw_title"] ||
                submod

            id = description["id"] || "module_#{no}"

            @titles << title
            @submod2id[submod] = id
            @id2submod[id] = submod

            no += 1
          end
        end
      end

      @submodules = deep_copy(new_submodules) # maybe some submodules are not installed
      log.info "Execution order after rewrite: #{@submodules}"

      if Yast::UI.TextMode
        # now build the menu button
        Yast::Builtins.foreach(@submodules_presentation) do |submod|
          descr = descriptions[submod] || {}
          next if descr.empty?

          no2 = descr["no"] || 0
          id = descr["id"] || "module_#{no2}"
          if descr.has_key? "menu_titles"
            descr["menu_titles"].each do |i|
              id2 = i["id"]
              title = i["title"]
              if id2 && title
                menu_list << Item(Id(id2), Yast::Ops.add(title, "..."))
              else
                log.info "Invalid menu item: #{i}"
              end
            end
          else
            menu_title = descr["menu_title"] ||
              descr["rich_text_title"] ||
              submod

            menu_list << Item(Id(id), menu_title + "...")
          end
        end

        # menu button item
        menu_list << Item(Id(:reset_to_defaults), _("&Reset to defaults")) <<
            Item(Id(:export_config), _("&Export Configuration"))

        # menu button
        Yast::UI.ReplaceWidget(
          Id(:rep_menu),
          MenuButton(Id(:menu), _("&Change..."), menu_list)
        )
      end

      return no > 1
    end

    def set_icon
      icon = case @proposal_mode
             when "network"
               "yast-network"
             when "hardware"
               "yast-controller"
             else
               @proposal_properties["icon"] || "yast-software"
             end

      Yast::Wizard.SetTitleIcon(icon)

      nil
    end

    def help_text
      help_text_string = ""

      # General part of the help text for all types of proposals
      how_to_change = _(
        "<p>\n" +
          "Change the values by clicking on the respective headline\n" +
          "or by using the <b>Change...</b> menu.\n" +
          "</p>\n"
      )

      if @proposal_mode == "initial" && Yast::Mode.installation
        # Help text for installation proposal
        # General part ("You can change values...") is added as the next paragraph.
        help_text_string = Yast::Ops.add(
          _(
            "<p>\n" +
              "Select <b>Install</b> to perform a new installation with the values displayed.\n" +
              "</p>\n"
          ),
          how_to_change
        )

        # kicking out, bug #203811
        # no such headline
        #	    // Help text for installation proposal, continued
        #	    help_text_string = help_text_string + _("<p>
        #To update an existing &product; system instead of doing a new install,
        #click the <b>Mode</b> headline or select <b>Mode</b> in the
        #<b>Change...</b> menu.
        #</p>
        #");
        # Deliberately omitting "boot installed system" here to avoid
        # confusion: The user will be prompted for that if Linux
        # partitions are found.
        # - sh@suse.de 2002-02-26
        #

        # Help text for installation proposal, continued
        help_text_string = Yast::Ops.add(
          help_text_string,
          _(
            "<p>\n" +
              "Your hard disk has not been modified yet. You can still safely abort.\n" +
              "</p>\n"
          )
        )
      elsif @proposal_mode == "initial" && Yast::Mode.update
        # Help text for update proposal
        # General part ("You can change values...") is added as the next paragraph.
        help_text_string = Yast::Ops.add(
          _(
            "<p>\n" +
              "Select <b>Update</b> to perform an update with the values displayed.\n" +
              "</p>\n"
          ),
          how_to_change
        )

        # Deliberately omitting "boot installed system" here to avoid
        # confusion: The user will be prompted for that if Linux
        # partitions are found.
        # - sh@suse.de 2002-02-26
        #

        # Help text for installation proposal, continued
        help_text_string = Yast::Ops.add(
          help_text_string,
          _(
            "<p>\n" +
              "Your hard disk has not been modified yet. You can still safely abort.\n" +
              "</p>\n"
          )
        )
      elsif @proposal_mode == "network"
        # Help text for network configuration proposal
        # General part ("You can change values...") is added as the next paragraph.
        help_text_string = Yast::Ops.add(
          _(
            "<p>\n" +
              "Put the network settings into effect by pressing <b>Next</b>.\n" +
              "</p>\n"
          ),
          how_to_change
        )
      elsif @proposal_mode == "service"
        # Help text for service configuration proposal
        # General part ("You can change values...") is added as the next paragraph.
        help_text_string = Yast::Ops.add(
          _(
            "<p>\n" +
              "Put the service settings into effect by pressing <b>Next</b>.\n" +
              "</p>\n"
          ),
          how_to_change
        )
      elsif @proposal_mode == "hardware"
        # Help text for hardware configuration proposal
        # General part ("You can change values...") is added as the next paragraph.
        help_text_string = Yast::Ops.add(
          _(
            "<p>\n" +
              "Put the hardware settings into effect by pressing <b>Next</b>.\n" +
              "</p>\n"
          ),
          how_to_change
        )
      elsif @proposal_mode == "uml"
        # Proposal in uml module
        help_text_string = _("<P><B>UML Installation Proposal</B></P>") +
          # help text
          _(
            "<P>UML (User Mode Linux) installation allows you to start independent\nLinux virtual machines in the host system.</P>"
          )
      elsif Yast::Ops.get_string(@proposal_properties, "help", "") != ""
        # Proposal help from control file module
        help_text_string = Yast::Ops.add(
          Yast::Builtins.dgettext(
            Yast::ProductControl.getProposalTextDomain,
            Yast::Ops.get_string(@proposal_properties, "help", "")
          ),
          how_to_change
        )
      else
        # Generic help text for other proposals (not basic installation or
        # hardhware configuration.
        # General part ("You can change values...") is added as the next paragraph.
        help_text_string = Yast::Ops.add(
          _(
            "<p>\n" +
              "To use the settings as displayed, press <b>Next</b>.\n" +
              "</p>\n"
          ),
          how_to_change
        )
      end

      if Yast::Ops.greater_than(Yast::Builtins.size(@locked_modules), 0)
        # help text
        help_text_string = Yast::Ops.add(
          help_text_string,
          _(
            "<p>Some proposals might be\n" +
              "locked by the system administrator and therefore cannot be changed. If a\n" +
              "locked proposal needs to be changed, ask your system administrator.</p>\n"
          )
        )
      end

      Yast::Builtins.foreach(@submodules_presentation) do |submod|
        if Yast::Ops.get(@submodule_helps, submod, "") != ""
          help_text_string = Yast::Ops.add(
            help_text_string,
            Yast::Ops.get(@submodule_helps, submod, "")
          )
        end
      end

      help_text_string
    end

    def SetNextButton
      if Yast::Stage.initial && @proposal_mode == "initial"
        Yast::Wizard.SetNextButton(
          :next,
          # FATE #120373
          Yast::Mode.update ?
            _("&Update") :
            _("&Install")
        )
      end

      nil
    end
  end
end
