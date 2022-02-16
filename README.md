
![Jabbers Ironman Roguelite](https://cdn.discordapp.com/attachments/415664512981794818/941835109521297448/Jabbers_Ironman_Roguelite.gif)  

**Jabbers' Ironman Roguelite**  
**Discord**: https://discord.gg/HRyCGesuXq  
**Twitch**: https://www.twitch.tv/jabbers_  
**Github**: https://github.com/jeffboulanger/Jabbers-Ironman-Roguelite  

**DEFINITION 'ROGUELITE'** 
 
A subgenre of roguelikes that has most of the game design philosophies of roguelikes but also has at least one progression element that persists after failure

**DESCRIPTION**

    This S.T.A.L.K.E.R Anomaly mod gives the player a more progressive approach to Ironman playthrough by allowing certain 
    aspects of a prior playthrough to be tracked and restored on successive playthroughs.  The system currently has 
    the following features...

**FEATURES**

- 100% Customizable Roguelite experience through MCM (or config parameters in the code if you prefer)
- 100% (as far as I know) conflict free from other mods.  Jabbers' Ironman Roguelite does not overwrite any scripts or ltx files and because of this it should not interfere with any other mods.   If it does please let me know so I can resolve.
- Restore player created stashes and items within between Ironman playthroughs
 - Player stashes are be marked on your PDA map just stash locations from missions
 - Item condition degredation applied to each applicable item between Ironman playthroughs
- Restore trader rep with optional penalty loss between Ironman playthroughs
 - Trader rep will never go below the value a trader receives at the start of a new game
- Restore character rep with optional penalty loss between Ironman playthroughs
 - Character rep will never go below the value the character receives at the start of a new game
- All Stashes/Items/Rep are saved based on faction so that seperate Ironman playthroughs of each faction do not interfere with each other.  IE: Stashes created on a Loner playthrough will not be seen on a Military playthrough and vice versa.
- Ability for other mods to save data to be used in concurent playthroughs
 - Create a script called "roguelite_module_<your module name>.script" 
 - Implemente the following global functions in your script
  - roguelite_load_state(data) - Loads data from the prior playthrough
  - roguelite_save_state(data) - Saves data when the player dies
  - append_mcm_options(gr) - Append any MCM options you want under the "Ironman Roguelite" MCM category

**INSTALLATION**

Simply extract into your S.T.A.L.K.E.R. Anomaly installation folder.

**FAQ**

**Q**: Doesn't this already exist with the Azazel game mode?  
**A**: Not really, while Azazel does allows you to continue as a new stalker after dieing, it's missing the "start over" aspect that Ironman provides.  In roguelite games, when you die, you are dead and you need to start over.  This is what Ironman is about.  That said, usually roguelite games also give you some sort of progression to make successive playthroughs a bit easier, usually through something like achievements, skills, items, etc.  This is what I hope to capture with this mod.

**Q**: How do I reset an Ironman playthrough so the stashes/rep/etc are not restored on my next playthrough  
**A**: Simply delete the file in appdata pertaining to the faction you want to start over with.  Ex: appdata/roguelite_actor_bandit.state
    
**Q**: I have an idea for progression that isnt included in this mod, how do I contact you.  
**A**: Well, the easiest way would be discord.  You can join my personal discord (https://discord.gg/HRyCGesuXq) and message me direct. I can also be found live most days on Twitch (https://www.twitch.tv/jabbers_) so feel free to stop by and say Hi! Additionally you can leave me a message on moddb... although this isnt my preferred communication platform so my response may be slower.   
    
**TODO**

- Implement some sort of Achievement based character progression system.  Example: Finishing the questline "Living Ledgend" might give the player a permanent bonus to carry weight.  This bonus would be applied on all successive Ironman playthroughs.  
- Restore learned recipes

**CHANGELOG**

- 0.1 - Initial Beta Release  
- 0.2 - [Update] Module API  
        [Fixed] Empty stashes on successive runs  
        [Fixed] Item uses would go to zero  
- 0.3 - [Added] Character rank support
        [Added] Haruka Skill System support as a proof of concept for external mod modules
        [Cleanup] MCM Menu
        [Cleanup] Debug Messages
