# These routines are used when WiKit is called for use with Tk

# Data structures ...
#
# pageWin    - name of text widget where we display the page contents.
# currMode   - No 'mode', but the string to search for in page titles.
#              Connected to the entry, traced ensures invocation of an
#              incremental search. Also holds the page title when using
#              the internal editor to manipulate a page's contents.
#
# pageStack  - History of pages visited to get to the current page.
#              Used by "Back" button.
# searchPage - Results generated by the incremental search.

package require Tk
package require Wikit::Db
package require Wikit::Search
package require Wikit::Lock

if {[catch {package require gbutton}]} {
    puts stderr "cannot load gbutton"
} else {
    package provide Wikit::Gui 1.1
    package require autoscroll
    
    namespace eval Wikit {
        
        namespace eval Color {
            variable wikiFg     "#000000"    # black
            variable wikiBg     "#ffffff"    # white
            variable btnDisable "#404040"    #
            variable linkFg     "#0000ff"    # blue
            variable linkActive "#ff0000"    # red
            variable fixedFg    "#8b0000"    # dark red
            variable fixedBg    "#e0e0e0"    # light gray
            variable codeBg  	white
            variable codeFg   	gray50
            variable copyBg     "#fafad2"    # Lightgoldenrodyellow
            variable bnormal    black        # normal button text
            variable bdisabled  darkgrey     # disabled button text
            
        }
        
        variable searchPage "" ;# avoid error when viewing before searching
        variable refPage 0     ;# boolean that indicates a reference page is currently displayed
        variable isLink 0      ;# boolean that indicates a link is being processed
        variable geomID	""	   ;# after ID for tracking geometry changes
		variable geomLast ""   ;# last saved geometry
	
		variable bindkey	   ;# keyboard bindings
		
		switch [tk windowingsystem] {
			aqua {
				set bindkey(Back)    {Command-[}
				set bindkey(Forward) {Command-]}
				set bindkey(Home)	 {Shift-Command-H}
				set bindkey(Cancel)  {Command-z}
				set bindkey(Save)	 {Command-s}
				set bindkey(Copy)	 {Command-c}
				set bindkey(Paste)	 {Command-v}
			}
			win32 -
			x11 {
				set bindkey(Back)    {Alt-Key-leftarrow}
				set bindkey(Forward) {Alt-Key-rightarrow}
				set bindkey(Home)	 {Alt-Key-home}
				set bindkey(Cancel)  {Control-z}
				set bindkey(Save)	 {Control-s}
			}
			default {
				set bindkey(Back) ""
				set bindkey(Front) ""
				set bindkey(Home) ""
			}
		}
		
        proc Expand_Tk {str} {
            global tcl_platform
            variable D
            
            set result [StreamToTk [TextToStream $str] [list ::Wikit::InfoProc wdb]]
            
            foreach {a b c} [lindex $result 1] {
                set tag $a$b
                
                $D tag bind $tag <Any-Enter> \
                        [namespace code [list linkActive $D $tag $Color::linkActive $c]]
                $D tag bind $tag <Any-Leave> \
                        [namespace code [list linkInactive $D $tag $Color::linkFg]]
                
                if {$a == "u" || $a == "x"} {
                    # Browsing in local mode is consistent for Windows,
                    # so render an underline and add a binding.
                    if { $tcl_platform(platform) == "windows" } {
                        $D tag configure $tag -font wikit_underline
                        $D tag bind $tag <ButtonPress-1> \
                                "eval exec [auto_execok start] $c &"
                    }
                }
                
                if {$a == "g"} {
                    set id [LookupPage $c]
                    $D tag bind $tag <ButtonPress-1> "Wikit::showLinkedPage $id"
                }
            }
            
            return [lreplace $result 1 1]
        }
        
        # highlight the link under the pointer
        proc linkActive { w tag color text } {
            variable linkText
            $w tag configure $tag -foreground $color
            set linkText $text
        }
        # un-highlight the link under the pointer
        proc linkInactive { w tag color } {
            variable linkText
            $w tag configure $tag -foreground $color
            set linkText ""
        }
        
        # Set the isLink value when following a link
        proc showLinkedPage { id } {
            variable isLink
            set isLink 1
            Wikit::ShowPage $id
        }
        
        # Show a page containing a list of links to all pages
        # referring to the page with the given id.
        proc ShowRefsPage {id} {
            variable D
            variable readonly
            variable top
            variable topwin
            variable refPage
            
            # set the refPage value when a reference page is displayed
            set refPage 1
            
            $D configure -cursor watch
            # Retrieve the title and list of references for the page with this id
            pagevars $id name
            
            # wm title $topwin "References to $name - WiKit"
            
            buttonState Edit disabled
            $D configure -state normal -font wiki_default
            $D delete 1.0 end
            $D insert end "References to $name" title
            
            # Generate a wiki formatted list of links.  One link for each reference
            set contents "\n"
            foreach r [mk::select wdb.refs to $id] {
                set r [mk::get wdb.refs!$r from]
                pagevars $r name
                append contents "   * \[$name]\n"
            }
            eval $D insert end [lindex [Expand_Tk $contents] 0]
            $D configure -state disabled
            focus $top.n.enter
            $D configure -cursor ""
            # setup a return to the page that requested the reference page
			setButton one Back "Wikit::ShowPage $id"
        }

        # Internal helper. Central functionality to render wiki pages in the
        # tk interface. Also associates functionality with the buttons in the
        # toolbar.
        #
        # Argument is the numerical id of the page as stored in the underlying
        # database. If no argument is given the history is used to step back
        # to the last page visited by the user.
        
        proc ShowPage {{id ""}} {
            variable D
            variable urlSeq
            variable currMode
            variable searchPage
            variable readonly
            variable top
            variable toppage
			variable HelpButton 
			
            set urlSeq 0
            
            $D configure -cursor watch
            if {!$readonly} {
				if {[getButton one] ne "Back"} {
                    # only update these if changed after edit
					setButton one Back Wikit::ShowPage
					setButton two Forward "Wikit::ShowPage -1"
					setButton three Home "Wikit::ShowPage $toppage"
					setButton four Edit Wikit::EditPage
                    bind $D <ButtonRelease-1> {}
                }
                buttonState Edit normal
            }
            
            # Record new page in transient viewing history (or retrieve it
            # from the history) and also import the relevant information from
            # the database into this context (the title of the page, its
            # format, and its contents). If any page different from the search
            # page is displayed we reset the entry to prevent further
            # incremental searching from interfering with the display, until
            # the user starts typing again.
            
            set id [History $id]
            pagevars $id name
            
            if {$id == 2} {
                set page $searchPage
            } else {
                set page [GetPage $id]
            }
            
            $top.n.mode configure -text Search:
            if {$id != 2} {
                set currMode ""
            }
            
            $D configure -state normal -font wikit_default
            $D delete 1.0 end
            
            # Setup for title backlinks
            if {[llength [mk::select wdb.refs to $id]] == 0} {
                set titleTags title
            } else {
                set titleTags [list title backlink]
                $D tag bind backlink <ButtonPress> "Wikit::ShowRefsPage $id"
            }
            
            # First we dynamically generate a script containing commands to
            # update the page window, then we execute the script, thus
            # rendering the page.
            
            set cmd "$D insert end {$name} {$titleTags} "
            
            set etk [Expand_Tk $page]
            append cmd [lindex $etk 0]
            
            eval $cmd
            foreach x [lindex $etk 1] {
                $D image create $x.first -image $x
            }
            
            $D configure -state disabled
            
            focus $top.n.enter
            if {$id == $toppage} {
                buttonState Home disabled
            } else {
                buttonState Home normal
            }
            if {$id == 3} {
                buttonState $HelpButton disabled
            } else {
                buttonState $HelpButton normal
            }
			if {$id == 2} {
                buttonState Edit disabled
			} else {
                buttonState Edit normal
			}
            $D configure -cursor ""
        }
        
        proc EditPage {} {
            variable D
            variable currMode
            variable pageStack
            variable top
			variable HelpButton
			
            set id [lindex $pageStack end]
            
            pagevars $id name page
            
            $D tag configure fixed -foreground {} -background {} \
					-font wikit_edit -wrap word
					
			setButton one Cancel "Wikit::EditCancel $id"
	      	setButton two Save "Wikit::EditSave $id"
			setButton three Copy Wikit::Copy disabled
			setButton four Paste Wikit::Paste disabled
            buttonState $HelpButton disabled		;# About/Help
            bind $D <ButtonRelease-1> Wikit::CopyCheck

            $top.n.mode configure -text "Edit Title:"
            set currMode $name

            $D configure -state normal -font wikit_edit
            $D delete 1.0 end
            $D insert end $page wikit_edit \n wikit_edit
            
            $D mark set insert 1.0
            
            focus $D
        }

		proc EditCancel {id} {
			variable D
        	$D tag configure fixed -foreground $Color::fixedFg \
 				-background $Color::fixedBg -font wikit_fixed -wrap none
			Wikit::ShowPage $id
		}
        
		proc EditSave {id} {
			variable D
			variable top
	        $D tag configure fixed -foreground $Color::fixedFg \
	 				-background $Color::fixedBg -font wikit_fixed -wrap none
	        Wikit::SavePage $id [$D get 1.0 end] local [$top.n.enter get]
	        Wikit::ShowPage $id
		} 
		
        proc History {page} {
            variable pageStack
            variable forwStack
            variable refPage
            variable isLink
			variable top
            if {$page == ""} {
                # Process <Back> button
                set forwStack [linsert $forwStack 0 [lindex $pageStack end]]
                set pageStack [lreplace $pageStack end end]
                set page [lindex $pageStack end]
                buttonState Forward normal
            } elseif {$page == -1} {
                # Process <Forward> button
                set page [lindex $forwStack 0]
                set forwStack [lreplace $forwStack 0 0]
                lappend pageStack $page
            } else {
                # Follow a page link
                if { $refPage == 0 } {
                    # Process a normal link (not on a ref page)
                    set forwStack [list]
                    if {$page != [lindex $pageStack end]} {
                        lappend pageStack $page
                    }
                } elseif { $isLink == 1 } {
                    # Process a link on a ref page
                    set forwStack [list]
                    if {$page != [lindex $pageStack end]} {
                        lappend pageStack $page
                    }
                }
            }
            # Back button may have been modified by ref page call so
            # restore Back button behavior
			setButton one Back Wikit::ShowPage
            
            if {[llength $forwStack] == 0} {
                buttonState Forward disabled
            }
            set state normal
            if {[llength $pageStack] <= 1} {
				buttonState Back disabled
			}
            
            # puts "history $page: $pageStack : $forwStack"
            # reset reference page flags
            set refPage 0
            set isLink 0
            return $page
        }
        
        proc LocalInterface {{win ""} {page 0}}  {
            global tcl_platform
            variable D
            variable currMode
            variable pageStack
            variable forwStack
            variable readonly
            variable top
            variable topwin
            variable toppage
            variable b0
            variable b1
            variable linkText
			variable fixedwid
			variable entry
			variable HelpButton
			
            set pageStack ""
            set forwStack ""
            
            set toppage $page
            set top $win
            
            set family arial
            set title 16
            set thin 4
            if {[string match Windows* $tcl_platform(os)]} {
                set default 9
                set buttonsize 9
            } else {
                set default 12
                set buttonsize 11
            }
            
            catch {
                font create wikit_default -family $family -size $default
                font create wikit_underline -family $family -size $default \
                        -underline true
                font create wikit_button -family $family -size $buttonsize
                font create wikit_title -family $family -size $title -weight bold
                font create wikit_edit -family courier -size $default -weight normal
                font create wikit_fixed -family courier -size $default -weight normal
                font create wikit_thin -family courier -size $thin
                font create wikit_bold -family $family -size $default -weight bold
                font create wikit_italic -family $family -size $default -slant italic
                font create wikit_bolditalic -family $family -size $default \
                        -weight bold -slant italic
				font create wikit_fixedbold -family courier -size $default \
											-weight bold
				font create wikit_fixeditalic -family courier -size $default \
											-weight normal -slant italic
				font create wikit_fixedbolditalic -family courier
			 						-size $default -weight bold -slant italic	        
		
                
                gButton::init -bg $Color::wikiBg -font wikit_button -disabledfill $Color::btnDisable
            }
            
			set fixedwid [font measure wikit_fixed " "]
			
            if {$top == ""} {
                set topwin "."
            } else {
                if {![winfo exists $top]} {
                    toplevel $top
                }
                set topwin [winfo toplevel $top]
            }
            if {![winfo exists $top.n]} {
                frame $top.n -relief raised -bg $Color::wikiBg -bd 1
                frame $top.n.f0 -background $Color::wikiBg
                set b0 [gButton #auto $top.n.f0]
                $b0 new one
                $b0 new two
                $b0 new three
                label $top.n.mode -width 7 -anchor e -bg $Color::wikiBg \
                        -fg $Color::wikiFg -font wikit_default
				set entry $top.n.enter
                entry $top.n.enter -textvariable Wikit::currMode -font wikit_default
                if {!$readonly} {
                    $b0 new four
					setButton four Edit "Wikit::EditPage"
                }
                $b0 size
                pack $top.n.f0 -side left -padx 0 -pady 0
                pack $top.n.mode -side left -padx 4 -pady 4
                pack $top.n.enter -side left -padx 4 -expand 1 -fill x
                frame $top.n.f1 -background $Color::wikiBg
                set b1 [gButton #auto $top.n.f1]
                $b1 new five
                $b1 size
                
                pack $top.n.f1 -side left -padx 0 -pady 0
                scrollbar $top.scroll -orient vertical -command [list $top.details yview]
                scrollbar $top.hbar -orient horizontal -command [list $top.details xview]
                label $top.status -anchor w -bg $Color::wikiBg -padx 4 -pady 4 \
                        -fg $Color::wikiFg -font wikit_default \
                        -textvariable [namespace which -variable linkText]
                text $top.details \
                        -yscrollcommand "$top.scroll set" \
                        -xscrollcommand "$top.hbar set" \
                        -width 72 \
                        -height 20 -state disabled -wrap word -font wikit_default \
                        -bg $Color::wikiBg -fg $Color::wikiFg -relief flat \
                        -exportselection 1 -selectbackground $Color::copyBg \
                        -selectforeground $Color::wikiFg
                
                grid $top.n -row 0 -column 0 -columnspan 2 -sticky new
                grid $top.details -row 1 -column 0 -sticky news
                grid $top.scroll -row 1 -column 1 -sticky ns
                grid $top.hbar -row 2 -column 0 -sticky news
                grid $top.status -row 3 -column 0 -sticky ew
                grid columnconfigure $topwin 0 -weight 1
                grid rowconfigure $topwin 1 -weight 1
                grid rowconfigure $topwin 1 -weight 1
                autoscroll::autoscroll $top.scroll
                autoscroll::autoscroll $top.hbar
                set D $top.details
                $D tag configure title -font wikit_title -lmargin1 3 -lmargin2 3
                $D tag configure backlink -foreground $Color::linkFg
                $D tag bind backlink <Any-Enter> \
                        "$D tag configure backlink -foreground $Color::linkActive"
                $D tag bind backlink <Any-Leave> \
                        "$D tag configure backlink -foreground $Color::linkFg"
                $D tag configure fixed -font wikit_fixed -wrap none \
						-lmargin1 3 -lmargin2 3 \
                        -foreground $Color::fixedFg \
						-background $Color::fixedBg
                $D tag configure code -font wikit_fixed -wrap none \
						-lmargin1 3 -lmargin2 3 \
                        -foreground $Color::codeFg \
						-background $Color::codeBg
		        $D tag configure fwrap -font wikit_fixed -wrap word \
						-lmargin1 3 -lmargin2 3 \
                        -foreground $Color::codeFg \
						-background $Color::codeBg
                $D tag configure body  -font wikit_default \
									   -lmargin1 3 -lmargin2 3

				# support for option lists - these need to be before the
				# declaration of i + b below (not sure why though?)
				$D tag configure optfix -font wikit_fixed \
								-foreground $Color::codeFg \
								-background $Color::codeBg
				
				$D tag configure optvar -font wikit_default -wrap word \
 								-lmargin1 3 -lmargin2 3

                $D tag configure url -font wikit_default -foreground $Color::linkFg
                $D tag configure urlq -font wikit_fixed -foreground $Color::linkFg

				# calculate the indent based on 3 spaces, a bullet and 2 spaces
				set in [expr {[font measure wikit_default "   \u2022  "] + 3}]			
                $D tag configure ul -font wikit_default -tabs 30 -lmargin1 3 \
														-lmargin2 $in

                $D tag configure ol -font wikit_default -lmargin1  3 -lmargin2 30 -tabs 30
                $D tag configure dt -font wikit_default -lmargin1  3 -lmargin2  3 -tabs 30
                $D tag configure dl -font wikit_default -lmargin1 30 -lmargin2 30 -tabs 30
                $D tag configure i -font wikit_italic
                $D tag configure b -font wikit_bold
                $D tag configure bi -font wikit_bolditalic
				$D tag configure fb -font wikit_fixedbold 
				$D tag configure fi -font wikit_fixeditalic
				$D tag configure fbi -font wikit_fixedbolditalic

                # support for horizontal lines
                $D tag configure thin -font wikit_thin
                $D tag configure hr -relief sunken -borderwidth 1 -wrap none
                bind $D <Configure> {%W tag configure hr -tabs [expr {%w-10}]}
				
				setButton one Back Wikit::ShowPage
                setButton two Forward "Wikit::ShowPage -1"
				set HelpButton [lindex [GetTitle 3] 0]
				setButton five $HelpButton "Wikit::ShowPage 3"
            }

            setButton three Home "Wikit::ShowPage $toppage"
            Wikit::ShowPage $page
            
            trace variable currMode w { after cancel Wikit::KeyTracker; after 500 Wikit::KeyTracker }
            wm title $topwin [GetTitle $page]
            wm protocol $topwin WM_DELETE_WINDOW [list destroy $topwin]
			# need to figure a way to get reasonable min size based on min
			# size needed to display buttons + search widget
			wm minsize $topwin [winfo reqwidth $topwin] \
							   [winfo reqheight $topwin]
			load_geom $topwin
            update
            after idle raise $topwin
			bind $topwin <Configure> [namespace code [list resize $topwin]]
            if {$topwin == "."} {
                tkwait window $topwin
            }
        }

		proc resize {win} {
			variable geomID
			variable geomLast
			if {$geomID ne ""} {
				after cancel $geomID
			} 	
			set geom [winfo geom $win]	
			if {$geom ne $geomLast} {
				set geomID [after 1000 [namespace code [list save_geom $geom]]]
			}
		}
		
		proc save_geom {geom} {
			variable geomLast
			set name [file tail $Wikit::wikifile]
			if {$::tcl_platform(platform) eq "windows"} {
				# save in the Registry
				set key HKEY_CURRENT_USER\\Software\\Wikit
				registry set $key $name $geom
			} else {
				# save in a metakit datafile, so we get atomic writes
				set info ~/.wikit.db
				set lock ~/.wikit.lock
				if {[Wikit::AcquireLock $lock]} {
					mk::file open info [file normalize $info]
					mk::view layout info.geom {name:S geom:S}
					set idx [mk::select info.geom name $name]
					if {$idx ne ""} {
						mk::set info.geom!$idx geom $geom
					} else {
						mk::row append info.geom name $name geom $geom
					}
					mk::file commit info
					mk::file close info
					Wikit::ReleaseLock $lock
				}
			}
			set geomLast $geom
		}
		
		proc load_geom {win} {
			variable geomLast
			set name [file tail $Wikit::wikifile]
			if {$::tcl_platform(platform) eq "windows"} {
				# load from the Registry
				set key HKEY_CURRENT_USER\\Software\\Wikit
				if {![catch {registry get $key $name}]} {
					set geom [registry get $key $name]
				}
			} else {
				# load from a metakit datafile
				set info ~/.wikit.db
				if {[file readable $info]} {
					mk::file open info [file normalize $info] -readonly
					set idx [mk::select info.geom name $name]
					if {$idx ne ""} {
						set geom [mk::get info.geom!$idx geom]

					}
					mk::file close info
				}
			}
			if {$geom ne $geomLast} {
				if {[tk windowingsystem] eq "aqua"} {
					set geom [check_geom_aqua $win $geom]
				} else {
					set geom [check_geom $win $geom]
				}
				wm geometry $win $geom
				set geomLast $geom
			}
		}
		
		proc check_geom {win geom {yoffset 0}} {
			# yoffset can be used to allow for a menubar (as in MacOS X Aqua)
			# or space at the bottom for window manager controls
			scan $geom "%ix%i+%i+%i" w h x y
			set sw [winfo screenwidth $win]
			set sh [winfo screenheight $win]
			if {$w + $x > $sw} {
				set x [expr {($sw - $w)/2}]
				set geom ""
			}
			if {$h + $y > $sh} {
				set y [expr {($sh - $y)/2}]
				set geom ""
			}	
			if {$y < $yoffset} {
				set y $yoffset
				set geom ""
			}
			if {$h + $yoffset*2 > $sh} {
				set h [expr {$sh - $yoffset*2}]
				set geom ""
			}
			if {$geom eq ""} {
				set geom =${w}x${h}+${x}+$y
			}
			return $geom
		}
		
		proc check_geom_aqua {win geom} {
			scan $geom "%ix%i+%i+%i" w h x y
			set cmd /usr/sbin/system_profiler
			if {[auto_execok $cmd] ne ""} {
				set fd [open "| $cmd SPDisplaysDataType"]
				set displaynum 0
		        foreach line [split [read $fd] \n] {
		            set fields [split [string trim $line] :]
		            set arg [string trim [lindex $fields 1]]
		            switch -- [lindex $fields 0] {
		                Resolution { incr displaynum }
		                Mirror     { set mirror [expr {$arg ne "Off"}] }
		            }   
		        }   
		        close $fd
		        if {$displaynum == 1 || $mirror} {
					# if a single display or mirrored we can trust Tk to
					# tell us the screen size
					return [check_geom $win $geom 20]
				}
	            set prefs /Library/Preferences/com.apple.windowserver
	            if {![catch {
					set fd [open "| defaults read $prefs DisplaySets"]
				}]} {
	                set lines [read $fd]
	                set num -1
	                foreach line [split [lindex [split $lines "()"] 2] \n] {
	                    set fields [split [string trim $line " ;"] =]
						set var [string trim [lindex $fields 0]]
	                    set val [string trim [lindex $fields 1]]
	                    switch -- $var {
	                        Active { incr num }
	                        OriginX -
	                        OriginY -
							Height { set $var $val }
							Width   {
								if {$num == 0} {
									# allow for menubar
									incr OriginY 20
								}
								# note the window must have at least 20 pixels
								# overlapping with the display (enough to move
								# via the window manager)
								lappend displays $num $OriginX $OriginY \
												[expr {$OriginX + $val - 20}] \
												[expr {$OriginY + $Height - 1}]
							}
	                    }
	                }
	                close $fd
					# look for top left on a display
					set found ""
					foreach {num x1 y1 x2 y2} $displays {
						if {$x >= $x1 && $x < $x2 && $y >= $y1 && $y < $y2} {
							set found $num
							break
						}
					}
					if {$found eq ""} {
						# look for top right on a display
						set ex [expr {$x + $w - 1}]
						foreach {num x1 y1 x2 y2} $displays {
						if {$ex >= $x1 && $ex < $x2 && $y >= $y1 && $y < $y2} {
								set found $num
								break
							}
						}
					}
					if {$found eq ""} {
						set geom [check_geom $win $geom]
						# not on any display, so we center on primary display
						foreach {num x1 y1 x2 y2} [lrange $displays 0 4] {}
						set x [expr {($x2 - $x1 - $w) / 2}]
						if {[set y [expr {($y2 - $y1 - $h) / 2}]] < $y1} {
							set y $y1
						}
				      	set geom =${w}x${h}+${x}+$y

					}
		        }
		    } 
			return $geom
		}
		

		# creates a tag to set the fixed width part of an option block
		# 	- converts from length to pixels using width of space char in the
		# 	  fixed width font
		proc optwid {n l} {
			variable D
			variable fixedwid
			set indent 5	;# indent from end of widest fixed part to var part
			set margin2 [expr {$fixedwid * $l + $fixedwid * $indent + 3}]
			# set margin2 [expr {$fixedwid * $l + 3}]
			$D tag configure optfix$n -font wikit_fixed -wrap word \
			 					   	-lmargin1 3 -lmargin2 $margin2 \
									-tabs [list ${margin2}p left] \
					               	-foreground $Color::codeFg \
									-background $Color::codeBg
			$D tag configure optvar$n -font wikit_default -wrap word \
					 			  	  -lmargin1 3 -lmargin2 $margin2
			$D tag configure vb -font wikit_bold 
			$D tag configure vi -font wikit_italic
			$D tag configure vbi -font wikit_bolditalic			                
		}
        
        proc KeyTracker {v op} {
            variable currMode
            variable searchKey
            variable searchLong
            variable searchPage
            variable pageStack
            
            # don't perform a search if:
            # we're not in browse mode
            #   (in edit mode, the entry field is used for the page title)
            # or
            # we're not on page 2 and the search box is empty
            #   (not on page two prevents searching when going back)
            #   (if the search box is not empty, a search key is present)
            # or
            # we're on page 2 and the search box is empty
            #   (return to previous page)
            
            #puts "KeyTracker [getButton four] [lindex $pageStack end] $currMode"
            
			set txt [getButton four]
            if {$txt != "" && $txt != "Edit"} return
            
            if {$currMode == ""} {
                if {[lindex $pageStack end] == 2} Wikit::ShowPage ;# pop last
                return
            }
            
            # keep iterating while the "currMode" search request changes
            while {1} {
                set cMode $currMode
                set sKey $currMode
                set sLong [regexp {^(.*)\*$} $sKey x sKey]
                
                if {$searchKey == $sKey && $searchLong == $sLong} break
                
                set searchKey $sKey
                set searchLong $sLong
                set rows [SearchList] ;# this takes time
                
                after cancel Wikit::KeyTracker
                update
                if {$currMode != $cMode} continue
                
                set searchPage [SearchResults $rows]
                
                after cancel Wikit::KeyTracker
                update
                if {$currMode == $cMode} break
            }
            
            Wikit::ShowPage 2
        }
        
        proc Copy {} {
	puts "Copy"
            clipboard clear
            if {![catch {set txt [selection get]}]} {
                clipboard append $txt
            }
puts $txt
        }
        
        proc Paste {} {
            variable D
            if {![catch {set txt [clipboard get]}] && $txt != ""} {
                $D insert insert [clipboard get] wikit_edit
            }
        }
        
        proc CopyCheck {} {
            if {[catch {set txt [selection get]}] || $txt == ""} {
                set state disabled
            } else {
                set state normal
            }
            buttonState Copy $state
        }

        proc buttonState {name state} {
			variable entry
			variable bindkey
			variable bindcmd
			variable button
			variable D
			set num $button($name)
            gButton::modify $num -state $state -fill [set Color::b$state]
			if {[info exists bindkey($name)]} {
				if {$state eq "normal"} {
					set cmd $bindcmd($num)
				} else {
					set cmd ""
				}
				# bind to both the entry and text widgets, so editing commands
				# work
				bind $entry <$bindkey($name)> $cmd
				bind $D <$bindkey($name)> $cmd
				focus .details
			}
        }

		proc setButton {num name cmd {state normal}} {
			variable entry
			variable bindkey
			variable bindcmd
			variable button
			variable D

			if {[info exists bindcmd($num)]} {
				# clear old keyboard binding
				bind $entry $bindcmd($num) {}
				bind $D $bindcmd($num) {}
			}
			gButton::modify $num -text $name -command $cmd
			if {[info exists bindkey($name)]} {
				set bindcmd($num) $cmd
			} else {
				set bindcmd($num) ""
			}
			set button($name) $num
			buttonState $name $state
		}
		
		proc getButton {num} {
			return [gButton::cget $num -text]
		}
        
    }
}


