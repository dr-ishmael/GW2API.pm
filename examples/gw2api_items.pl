#!perl

use Modern::Perl '2014';

use DateTime;
use DBI;
use Term::ProgressBar;

use threads;
use threads::shared;
use Thread::Queue;

use GuildWars2::API;
use GuildWars2::API::Utils;

my $VERBOSE = 0;

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst);

###
# Set up API interface
my $boss_api = GuildWars2::API->new();

# Read config info for database
# This file contains a single line, of the format:
#   <database_type>,<database_name>,<schema_name>,<schema_password>
#
# where <database_type> corresponds to the DBD module for your database.
#
my @db_keys = qw(type schema user pass);
my @db_vals;
open(DB,"database_info.conf") or die "Can't open db info file: $!";
while (<DB>) {
  chomp;
  @db_vals = split (/,/);
  last;
}
close(DB);
my %db :shared;
@db{@db_keys} = @db_vals;

if (defined($ARGV[0]) && $ARGV[0] eq "test") {
  $db{'schema'} = $db{'schema'} . "_test";
}


# Connect to database
my $boss_dbh = DBI->connect('dbi:'.$db{'type'}.':'.$db{'schema'}, $db{'user'}, $db{'pass'},{mysql_enable_utf8 => 1})
  or die "Can't connect: $DBI::errstr\n";


# Get the last known build ID from database
print "Looking up last known build ID....." if $VERBOSE;
my $sth_get_build = $boss_dbh->prepare("select ifnull(max(build_id),-1) from build_tb where items_processed = 'Y'")
  or die "Can't prepare statement: $DBI::errstr";

my $max_build_id = $boss_dbh->selectrow_array($sth_get_build)
  or die "Can't execute statement: $DBI::errstr";

say " $max_build_id" if $VERBOSE;

# Get the current build ID from API
print "Getting current build ID from API..." if $VERBOSE;
my $curr_build_id :shared = $boss_api->build();
say " $curr_build_id" if $VERBOSE;

# Update database if new build
my $new_build :shared = 0;

if ($curr_build_id > $max_build_id) {
  say "New build detected! All items will be re-fecthed from the API.";
  $new_build = 1;
  # IGNORE in this statement is in case the recipe or skin processes have already run for this build
  $boss_dbh->do('insert IGNORE into build_tb (build_id) values (?)', {}, $curr_build_id)
    or die "Can't execute statement: $DBI::errstr";
} else {
  say "Not a new build, existing items will be skipped.";
}

# Get current MD5 and last build ID for all items from database
my %item_md5s :shared;

say "Retrieving local MD5 data..." if $VERBOSE;
my $sth_item_md5 = $boss_dbh->prepare("select item_id, item_md5 from item_tb")
  or die "Can't prepare statement: $DBI::errstr";

$sth_item_md5->execute() or die "Can't execute statement: $DBI::errstr";

while (my $i = $sth_item_md5->fetchrow_arrayref()) {
  $item_md5s{$i->[0]} = $i->[1];
}
say scalar(keys %item_md5s) . " total items in database.";

# Get list of items from API
say "Getting current list of items..." if $VERBOSE;
my @api_item_ids = $boss_api->list_items();

my $tot_items = scalar @api_item_ids;
say $tot_items . " total items in API.";

my @proc_item_ids;
my $proc_items;
if ($new_build) {
  @proc_item_ids = @api_item_ids;
} else {
  # This computes the list disjunction of items in the API against items in our database.
  # We only need to spend time processing items we don't already know.
  @proc_item_ids  = grep {not $item_md5s{$_}} @api_item_ids;
}

$proc_items = scalar @proc_item_ids;

if ($proc_items == 0) {
  # Short-circuit exit if nothing new to process
  say "No new items to process; script will now exit";
  exit(0);
} elsif ($proc_items == $tot_items) {
  say "All items will be re-processed.";
} else{
  say $proc_items . " new items to be processed.";
}

say "Redirecting STDERR to gw2api.err; please check this file for any warnings or errors generated during the process.";
open(my $olderr, ">&", \*STDERR) or die "Can't dup STDERR: $!";
open(STDERR, ">", ".\\gw2api.err") or die "Can't redirect STDERR: $!";
select STDERR; $| = 1;  # make unbuffered

select STDOUT;

say "Ready to begin processing.";

###
# THREADING! SCARY!
# boss/worker model copied from http://cpansearch.perl.org/src/JDHEDDEN/threads-1.92/examples/pool_reuse.pl

# Maximum working threads
my $MAX_THREADS = 4;

# Flag to inform all threads that application is terminating
my $TERM :shared = 0;

# Size of each work batch (how many items a thread processes at once)
my $WORK_SIZE :shared = 200;

# Threads add their ID to this queue when they are ready for work
# Also, when app terminates a -1 is added to this queue
my $IDLE_QUEUE = Thread::Queue->new();

# Gracefully terminate application on ^C or command line 'kill'
$SIG{'INT'} = $SIG{'TERM'} =
    sub {
        print(">>> Terminating <<<\n");
        $TERM = 1;
        # Add -999 to head of idle queue to signal boss-initiated termination
        $IDLE_QUEUE->insert(0, -999);
    };

# Thread work queues referenced by thread ID
my %work_queues;

# Create queues for threads to report new/changed item_ids back to the boss
my $new_q = Thread::Queue->new();
my $updt_q = Thread::Queue->new();

# Create the thread pool
for (1..$MAX_THREADS) {
  # Create a work queue for a thread
  my $work_q = Thread::Queue->new();

  # Create the thread, and give it the work queue
  my $thr = threads->create('worker', $work_q);

  # Remember the thread's work queue
  $work_queues{$thr->tid()} = $work_q;
}

my $i = 0;
my @new_item_arr;
my @updt_item_arr;

($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
say "Entering threaded mode at " . sprintf("%02d:%02d:%02d", $hour, $min, $sec);

my $progress = Term::ProgressBar->new({name => 'Items processed', count => $tot_items, fh => \*STDOUT});
$progress->minor(0);
my $next_update = 0;

# Manage the thread pool until signalled to terminate
while (! $TERM) {
    # Wait for an available thread
    my $tid = $IDLE_QUEUE->dequeue();

    # Update progress bar here because work has completed at this point
    $next_update = $progress->update($i)
      if $i >= $next_update;

    # Check for termination condition
    if ($tid < 0) {
      $tid = -$tid;
      # If we initiated the termination, break the loop
      last if $tid == 999;
      # If a worker terminated, clean it up
      #threads->object($tid)->join();
    }
    last if (scalar @proc_item_ids == 0);

    # Give the thread some work to do
    my @ids_to_process = splice @proc_item_ids, 0, $WORK_SIZE;
    $work_queues{$tid}->enqueue(@ids_to_process);

    $i += scalar @ids_to_process;
}

$progress->update($tot_items)
  if $tot_items >= $next_update;
say "";

# Signal all threads that there is no more work
$work_queues{$_}->end() foreach keys(%work_queues);

# Wait for all the threads to finish
$_->join() foreach threads->list();

($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
say "All threads complete at " . sprintf("%02d:%02d:%02d", $hour, $min, $sec);

# Set first_seen_build_id for all new items
my $sth_new_item_updt = $boss_dbh->prepare('
   update item_tb
   set first_seen_build_id = ?
   where first_seen_build_id is null
')
or die "Can't prepare statement: $DBI::errstr";

$sth_new_item_updt->execute($curr_build_id);

# Take note of new/updated item_ids passed back from threads
while ($new_q->pending() > 0) { push @new_item_arr, $new_q->dequeue(); }
while ($updt_q->pending() > 0) { push @updt_item_arr, $updt_q->dequeue(); }

my $now = DateTime->now(time_zone  => 'America/Chicago');

my $rpt_filename = "gw2api_items_report_".$now->ymd('').$now->hms('').".txt";

open(RPT, ">", $rpt_filename) or die "Can't open report file: $!";

say RPT "NEW";
say RPT "--------";
say RPT $_ foreach (sort { $a <=> $b } @new_item_arr);
say RPT "";
say RPT "CHANGE";
say RPT "--------";
say RPT $_ foreach (sort { $a <=> $b } @updt_item_arr);

close(RPT);

say "";
say "GW2API Items Report";
say "";
say "Statistic  Count";
say "---------- --------";
say sprintf '%-10s %8s', 'TOTAL', $tot_items;
say sprintf '%-10s %8s', 'PROCESSED', $proc_items;
say sprintf '%-10s %8s', 'NEW', scalar @new_item_arr;
say sprintf '%-10s %8s', 'CHANGES', scalar @updt_item_arr;

say "";
say "For details see $rpt_filename";

open(STDERR, ">&", $olderr)    or die "Can't dup OLDERR: $!";


# If this was the first time processing this build, update the processed flag
if ($new_build) {
  $boss_dbh->do("update build_tb set items_processed = 'Y' where build_id = ?", {}, $curr_build_id)
    or die "Unable to updated items_processed flag: $DBI::errstr";
}

exit(0);





######################################
### Thread Entry Point Subroutines ###
######################################

# A worker thread
sub worker
{
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst);
  # Hook into the work queue assigned to us
  my ($work_q) = @_;

  # This thread's ID
  my $tid = threads->tid();

  # Open a log file
  my $log;
  if ($VERBOSE) {
    $log = IO::File->new(">>gw2api_items_t$tid.log");
    if (!defined($log)) {
      die "Can't open logfile: $!";
    }
    $log->autoflush;
  }

  say $log "This is thread $tid starting up!" if $VERBOSE;

  my @item_ids;
  my $item_id;

  # Signal the boss if this thread dies
  $SIG{__DIE__} = sub {
      my @loc = caller(1);
      say STDERR ">>> Thread $tid (fake) died! <<<";
      if (defined($item_id)) { say STDERR ">>> Item id: $item_id <<<" }
      say STDERR "Kill happened at line $loc[2] in $loc[1]:\n", @_;
      # Add -$tid to head of idle queue to signal termination
      $IDLE_QUEUE->insert(0, -$tid);
      return 1;
  };

  # Create our very own API object
  my $api = GuildWars2::API->new();

  # Open a database connection
  say $log "Opening database connection." if $VERBOSE;
  my $dbh = DBI->connect('dbi:'.$db{'type'}.':'.$db{'schema'}, $db{'user'}, $db{'pass'},{mysql_enable_utf8 => 1})
    or die "Can't connect: $DBI::errstr\n";
  say $log "\tDatabase connection established." if $VERBOSE;

  say $log "Beginning work loop." if $VERBOSE;

  # Work loop
  while (! $TERM) {
    # If the boss has closed the work queue, exit the work loop
    if (!defined($work_q->pending())) {
      say $log "Work queue is closed, exiting work loop." if $VERBOSE;
      last;
    }

    # If we have completed all work in the queue...
    if ($work_q->pending() == 0) {
      say $log "Work queue is empty, signaling ready state." if $VERBOSE;
      # ...indicate that were are ready to do more work
      $IDLE_QUEUE->enqueue($tid);
    }

    # Wait for work from the queue
    say $log "Getting work from the queue..." if $VERBOSE;
    @item_ids = $work_q->dequeue($WORK_SIZE);
    if (!defined($item_ids[0])) {
      say $log "\tQueue returned undef! I quit." if $VERBOSE;
      last;
    }
    say $log "\tGot work: " . scalar @item_ids . " items" if $VERBOSE;

    #################################
    # HERE'S ALL THE WORK
    # Loop over the item_ids we dequeued
    my @seen_item_ids = ();
    my @changed_item_ids = ();
    my @changed_item_data = ();
    my @changed_item_attr_data = ();
    my @changed_item_rune_data = ();

    my $changed_item_cnt = 0;
    my $changed_rune_cnt = 0;
    my $changed_attr_cnt = 0;

    my @items = $api->get_items(\@item_ids);

    #if ($items[0]->can('error')) {
    #  say STDERR "API returned an error! Aborting item...";
    #  next;
    #  ### might need more code here to "clean up" database on errors ###
    #}

    foreach my $i (@items) {

      my $change_flag = 0;
      my $item_id = $i->{json}->{id};

      say $log "Looking up existing MD5..." if $VERBOSE;
      my $old_md5 = $item_md5s{$item_id};
      if ($old_md5) {
        say $log "\tExisting MD5 is $old_md5." if $VERBOSE;

        if ($old_md5 eq $i->{md5}) {
          # No change
          say $log "MD5 unchanged, will update last_seen_dt." if $VERBOSE;
          push @seen_item_ids, $item_id;
        } else {
          say $log "New MD5 is ".$i->{md5}.", item data has changed." if $VERBOSE;
          $change_flag = 1;
          push @changed_item_ids, $item_id;
          $updt_q->enqueue($item_id);
        }
      } else {
        say $log "\tItem is new." if $VERBOSE;
        $change_flag = 1;
        push @changed_item_ids, $item_id;
        $new_q->enqueue($item_id);
      }

      if ($change_flag) {
        my $item_prefix;

        my $item = GuildWars2::API::Objects::Item->new($i->{json});

        if (in($item->item_type, [ 'Armor', 'Back', 'Trinket', 'Weapon', ] ) ) {
          say $log "Item is equippable, determining prefix..." if $VERBOSE;
          $item_prefix = $api->prefix_lookup($item);
          say $log "\tItem prefix is $item_prefix." if $VERBOSE;
        }


        say $log "Preparing new/updated item data..." if $VERBOSE;

        push (@changed_item_data
          ,$item->item_id
          ,$item->item_name
          ,$item->item_type
          ,$item->item_subtype
          ,$item->level
          ,$item->rarity
          ,$item->description
          ,$item->vendor_value
          ,$item->game_type_flags->Activity
          ,$item->game_type_flags->Dungeon
          ,$item->game_type_flags->Pve
          ,$item->game_type_flags->Pvp
          ,$item->game_type_flags->PvpLobby
          ,$item->game_type_flags->Wvw
          ,$item->item_flags->AccountBindOnUse
          ,$item->item_flags->AccountBound
          ,$item->item_flags->HideSuffix
          ,$item->item_flags->NoMysticForge
          ,$item->item_flags->NoSalvage
          ,$item->item_flags->NoSell
          ,$item->item_flags->NotUpgradeable
          ,$item->item_flags->NoUnderwater
          ,$item->item_flags->SoulbindOnAcquire
          ,$item->item_flags->SoulBindOnUse
          ,$item->item_flags->Unique
          ,$item->icon_url
          ,$item->default_skin
          ,$item_prefix
          ,$item->infusion_slot_1_type
          ,$item->infusion_slot_1_item
          ,$item->infusion_slot_2_type
          ,$item->infusion_slot_2_item
          ,$item->suffix_item_id
          ,$item->second_suffix_item_id
          ,$item->buff_skill_id
          ,$item->buff_desc
          ,$item->armor_weight
          ,$item->armor_race
          ,$item->defense
          ,$item->bag_size
          ,$item->invisible
          ,$item->food_duration_sec
          ,$item->food_description
          ,$item->charges
          ,$item->unlock_type
          ,$item->unlock_color_id
          ,$item->unlock_recipe_id
          ,$item->upgrade_type
          ,$item->suffix
          ,$item->infusion_type
          ,$item->damage_type
          ,$item->min_strength
          ,$item->max_strength
          ,$item->item_warnings
          ,$i->{md5}
          ,$curr_build_id
          ,$curr_build_id
          ,$curr_build_id
        );

        $changed_item_cnt++;

        if (ref($item->rune_bonuses) eq 'ARRAY') {
          for my $b (0..$#{$item->rune_bonuses}) {
            my $bonus = $item->rune_bonuses->[$b];
            push (@changed_item_rune_data, $item_id, $b, $bonus);
            $changed_rune_cnt++;
          }
        }

        if (ref($item->item_attributes) eq 'HASH') {
          my $ia = $item->item_attributes;
          for my $a (keys %$ia) {
            my $v = $ia->{$a};
            push (@changed_item_attr_data, $item_id, $a, $v);
            $changed_attr_cnt++;
          }
        }

      }

      say $log "\tCompleted processing item $item_id." if $VERBOSE;

    }

    # We've processed a full batch of items, time to post everything to the database

    if (scalar @seen_item_ids > 0) {
      my $seen_item_id_list = join(',', @seen_item_ids);
      my $sth_update_item_data = $dbh->prepare("
          update item_tb
          set last_seen_build_id = $curr_build_id, last_seen_dt = current_timestamp
          where item_id in ($seen_item_id_list)
        ")
        or die "Can't prepare statement: $DBI::errstr";

      $sth_update_item_data->execute();
    }

    if (scalar @changed_item_ids > 0) {
      my $changed_item_id_list = join(',', @changed_item_ids);

      # Copy existing item data to log table
      my $sth_log_item_data = $dbh->prepare("
          insert into item_log_tb
          select a.*, $curr_build_id, current_date from item_tb a where item_id in ($changed_item_id_list)
        ")
        or die "Can't prepare statement: $DBI::errstr";

      $sth_log_item_data->execute();

      # Replace base item data
      my $sth_replace_item_data = $dbh->prepare('
          insert into item_tb (item_id, item_name, item_type, item_subtype, item_level, item_rarity, item_description, vendor_value, game_type_activity, game_type_dungeon, game_type_pve, game_type_pvp, game_type_pvplobby, game_type_wvw, flag_accountbindonuse, flag_accountbound, flag_hidesuffix, flag_nomysticforge, flag_nosalvage, flag_nosell, flag_notupgradeable, flag_nounderwater, flag_soulbindonacquire, flag_soulbindonuse, flag_unique, icon_url, default_skin, equip_prefix, equip_infusion_slot_1_type, equip_infusion_slot_1_item_id, equip_infusion_slot_2_type, equip_infusion_slot_2_item_id, suffix_item_id, second_suffix_item_id, buff_skill_id, buff_description, armor_class, armor_race, armor_defense, bag_size, bag_invisible, food_duration_sec, food_description, tool_charges, unlock_type, unlock_color_id, unlock_recipe_id, upgrade_type, upgrade_suffix, upgrade_infusion_type, weapon_damage_type, weapon_min_strength, weapon_max_strength, item_warnings, item_md5, first_seen_build_id, first_seen_dt, last_seen_build_id, last_seen_dt, last_updt_build_id, last_updt_dt)
          values ' .
          join(',', ("(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, current_timestamp, ?, current_timestamp, ?, current_timestamp)") x $changed_item_cnt )
      . 'on duplicate key update
        item_name=VALUES(item_name)
       ,item_type=VALUES(item_type)
       ,item_subtype=VALUES(item_subtype)
       ,item_level=VALUES(item_level)
       ,item_rarity=VALUES(item_rarity)
       ,item_description=VALUES(item_description)
       ,vendor_value=VALUES(vendor_value)
       ,game_type_activity=VALUES(game_type_activity)
       ,game_type_dungeon=VALUES(game_type_dungeon)
       ,game_type_pve=VALUES(game_type_pve)
       ,game_type_pvp=VALUES(game_type_pvp)
       ,game_type_pvplobby=VALUES(game_type_pvplobby)
       ,game_type_wvw=VALUES(game_type_wvw)
       ,flag_accountbindonuse=VALUES(flag_accountbindonuse)
       ,flag_accountbound=VALUES(flag_accountbound)
       ,flag_hidesuffix=VALUES(flag_hidesuffix)
       ,flag_nomysticforge=VALUES(flag_nomysticforge)
       ,flag_nosalvage=VALUES(flag_nosalvage)
       ,flag_nosell=VALUES(flag_nosell)
       ,flag_notupgradeable=VALUES(flag_notupgradeable)
       ,flag_nounderwater=VALUES(flag_nounderwater)
       ,flag_soulbindonacquire=VALUES(flag_soulbindonacquire)
       ,flag_soulbindonuse=VALUES(flag_soulbindonuse)
       ,flag_unique=VALUES(flag_unique)
       ,icon_url=VALUES(icon_url)
       ,default_skin=VALUES(default_skin)
       ,equip_prefix=VALUES(equip_prefix)
       ,equip_infusion_slot_1_type=VALUES(equip_infusion_slot_1_type)
       ,equip_infusion_slot_1_item_id=VALUES(equip_infusion_slot_1_item_id)
       ,equip_infusion_slot_2_type=VALUES(equip_infusion_slot_2_type)
       ,equip_infusion_slot_2_item_id=VALUES(equip_infusion_slot_2_item_id)
       ,suffix_item_id=VALUES(suffix_item_id)
       ,second_suffix_item_id=VALUES(second_suffix_item_id)
       ,buff_skill_id=VALUES(buff_skill_id)
       ,buff_description=VALUES(buff_description)
       ,armor_class=VALUES(armor_class)
       ,armor_race=VALUES(armor_race)
       ,armor_defense=VALUES(armor_defense)
       ,bag_size=VALUES(bag_size)
       ,bag_invisible=VALUES(bag_invisible)
       ,food_duration_sec=VALUES(food_duration_sec)
       ,food_description=VALUES(food_description)
       ,tool_charges=VALUES(tool_charges)
       ,unlock_type=VALUES(unlock_type)
       ,unlock_color_id=VALUES(unlock_color_id)
       ,unlock_recipe_id=VALUES(unlock_recipe_id)
       ,upgrade_type=VALUES(upgrade_type)
       ,upgrade_suffix=VALUES(upgrade_suffix)
       ,upgrade_infusion_type=VALUES(upgrade_infusion_type)
       ,weapon_damage_type=VALUES(weapon_damage_type)
       ,weapon_min_strength=VALUES(weapon_min_strength)
       ,weapon_max_strength=VALUES(weapon_max_strength)
       ,item_warnings=VALUES(item_warnings)
       ,item_md5=VALUES(item_md5)
       ,last_seen_build_id=VALUES(last_seen_build_id)
       ,last_seen_dt=current_timestamp
       ,last_updt_build_id=VALUES(last_updt_build_id)
       ,last_updt_dt=current_timestamp
       ') or die "Can't prepare statement: $DBI::errstr";

      $sth_replace_item_data->execute(@changed_item_data) or die "Can't execute statement: $DBI::errstr";

      if (scalar @changed_item_rune_data > 0) {
        # Delete existing rune data
        my $sth_delete_rune_data = $dbh->prepare("delete from item_rune_bonus_tb where item_id in ($changed_item_id_list)")
          or die "Can't prepare statement: $DBI::errstr";

        $sth_delete_rune_data->execute();

        # Insert rune data
        my $sth_insert_rune_data = $dbh->prepare('insert into item_rune_bonus_tb values '
            . join(',', ("(?, ?, ?)") x scalar $changed_rune_cnt )
          ) or die "Can't prepare statement: $DBI::errstr";

        $sth_insert_rune_data->execute(@changed_item_rune_data) or die "Can't execute statement: $DBI::errstr";
      }

      if (scalar @changed_item_attr_data > 0) {
        # Delete existing attr data
        my $sth_delete_attr_data = $dbh->prepare("delete from item_attribute_tb where item_id in ($changed_item_id_list)")
          or die "Can't prepare statement: $DBI::errstr";

        $sth_delete_attr_data->execute();

        # Insert attribute data
        my $sth_insert_attr_data = $dbh->prepare('insert into item_attribute_tb values '
            . join(',', ("(?, ?, ?)") x scalar $changed_attr_cnt )
          ) or die "Can't prepare statement: $DBI::errstr";

        $sth_insert_attr_data->execute(@changed_item_attr_data) or die "Can't execute statement: $DBI::errstr";
      }
    }

    @changed_item_data = ();
    @changed_item_rune_data = ();
    @changed_item_attr_data = ();

    $changed_item_cnt = 0;
    $changed_rune_cnt = 0;
    $changed_attr_cnt = 0;

#($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
#say "Thread $tid completed a batch at " . sprintf("%02d:%02d:%02d", $hour, $min, $sec);

    # Continue looping until told to terminate or queue is closed
  }

  say $log "Boss signaled abnormal termination." if $TERM && $VERBOSE;

  # All done
  say $log "Terminating database connection..." if $VERBOSE;
  $dbh->disconnect;
  say $log "\tDatabase connection terminated." if $VERBOSE;

  say $log "This is thread $tid signing off." if $VERBOSE;
  $log->close if $VERBOSE;

}
