if fs.exists("/xreactor/installer/installer.lua") then
  shell.run("/xreactor/installer/installer.lua")
else
  print("XReactor installer not found in /xreactor.")
  print("Copy the xreactor folder first, then run this installer again.")
end
