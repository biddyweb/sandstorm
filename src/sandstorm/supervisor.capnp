# Sandstorm - Personal Cloud Sandbox
# Copyright (c) 2014 Sandstorm Development Group, Inc. and contributors
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

@0xc7205d6d32c7b040;
# This file contains interfaces defining communication between a Sandstorm grain supervisor and
# other components of the sysetm. These interfaces are NOT used by Sandstorm applications.

$import "/capnp/c++.capnp".namespace("sandstorm");

using Util = import "util.capnp";
using Grain = import "grain.capnp";
using Persistent = import "/capnp/persistent.capnp".Persistent;

interface Supervisor {
  # Default capability exported by the supervisor process.

  getMainView @0 () -> (view :Grain.UiView);
  # Get the grain's main UiView.

  keepAlive @1 ();
  # Must call periodically to prevent supervisor from killing itself off.  Call at least once
  # per minute.

  syncStorage @8 ();
  # Calls syncfs() on /var.

  shutdown @2 ();
  # Shut down the grain immediately.  Useful e.g. when upgrading to a newer app version.  This
  # call will never return successfully because the process kills itself.

  getGrainSize @3 () -> (size :UInt64);
  # Get the total storage size of the grain.

  getGrainSizeWhenDifferent @4 (oldSize :UInt64) -> (size :UInt64);
  # Wait until the storage size of the grain is different from `oldSize` and then return the new
  # size. May occasionally return prematurely, with `size` equal to `oldSize`.

  restore @5 (ref :SupervisorObjectId, requirements :List(MembraneRequirement))
          -> (cap :Capability);
  # Wraps `MainView.restore()`. Can also restore capabilities hosted by the supervisor.
  #
  # `requirements` lists any conditions which, if they become untrue, should cause the capability --
  # and any future capabilities which pass through it -- to be revoked. The supervisor creates a
  # membrane around the returned capability which will be revoked if any of these requirements
  # fail. Additionally, the membrane will ensure that any capabilities save()d after passing
  # through this membrane have these requirements applied as well.

  drop @6 (ref :SupervisorObjectId);
  # Wraps `MainView.drop()`. Can also drop capabilities hosted by the supervisor.

  watchLog @7 (backlogAmount :UInt64, stream :Util.ByteStream) -> (handle :Util.Handle);
  # Write the last `backlogAmount` bytes of the grain's debug log to `stream`, and then watch the
  # log for changes, writing them to `stream` as they happen, until `handle` is dropped.
}

interface SandstormCore {
  # When the front-end connects to a Sandstorm supervisor, it exports a SandstormCore capability as
  # the default capability on the connection. This SandstormCore instance is specific to the
  # supervisor's grain; e.g. the grain ID is used to enforce ownership restrictions in `restore()`
  # and to fill out the `grainId` field in the `ApiTokens` table in calls to `wrapSaved()`.
  #
  # If the front-end disconnects, it probably means that it is restarting. It will connect again
  # after restart. In the meantime, the supervisor should queue any RPCs to this interface and
  # retry them after the front-end has reconnected.

  restore @0 (token :Data, requiredPermissions :Grain.PermissionSet) -> (cap :Capability);
  # Restores an API token to a live capability. Fails if this grain is not the token's owner
  # (including if the ref has no owner).
  #
  # `requiredPermissions` has the same meaning as in SandstormApi.restore(). Note that the callee
  # will not only check these requirements, but will automatically ensure that the returned
  # capability has an appropriate `MembraneRequirement` applied; the caller need not concern
  # itself with this.

  drop @3 (token :Data);
  # Deletes the corresponding API token. See `MainView.drop()` for discussion of dropping.

  makeToken @1 (ref :SupervisorObjectId, owner :ApiTokenOwner,
                requirements :List(MembraneRequirement)) -> (token :Data);
  # When the supervisor receives a save() request for a capability hosted by the app, it first
  # calls save() on the underlying capability to get an AppObjectId, then calls makeToken() to
  # convert this to a token which it can then return.
  #
  # Similarly, when the supervisor receives a save() request for a capability it itself hosts
  # (outside of the app), it constructs the appropriate `SupervisorObjectId` and passes it to
  # `makeToken()`.
  #
  # If any of the conditions listed in `requirements` become untrue, the returned token will be
  # disabled (cannot be restored).

  getOwnerNotificationTarget @2 () -> (owner :Grain.NotificationTarget);
  # Get the notification target to use for notifications relating to the grain itself, e.g.
  # presence of wake locks.

  checkRequirements @4 (requirements :List(MembraneRequirement))
                    -> (observer :RequirementObserver);
  # Verifies that all the requirements in the list are met, throwing an exception if one or more
  # are not met.

  interface RequirementObserver {
    observe @0 ();
    # Does not return as long as the requirements remains met. If at some point a requirement is
    # broken, throws an exception. When implementing a membrane based on this, after an exception
    # is thrown, the membrane should begin throwing the same exception from all methods called
    # through it.
    #
    # The caller may cancel this call via normal Cap'n Proto cancellation. (The callee must
    # implement cancellation correctly.)
    #
    # Note that the callee may choose to pessimistically throw a DISCONNECTED exception if the
    # requirements *might* have changed (but might not have). This will naturally force the
    # application to re-restore() all capabilities which will lead to a full requirement check
    # being performed. Thus, the implementation of RequirementObserver need not actually remember
    # the exact requirement list, but only enough information to detect when they _might_ have
    # been broken.
  }
}

struct MembraneRequirement {
  # Indicates some condition which, if it becomes untrue, will cause a membrane to be revoked.

  union {
    tokenValid @0 :Text;
    # This token is valid only as long as some *other* token is also still valid. `tokenValid`
    # specifies the `_id` of the other ApiToken.

    permissionsHeld :group {
      # This token is valid only as long as some specified user holds some specified set of
      # permissions on some specified grain.

      userId @1 :Text;
      # The user who must hold the permissions.

      grainId @2 :Text;
      # The grain on which the permissions must be held.

      permissions @3 :Grain.PermissionSet;
      # The permissions the user must hold on the grain.
    }
  }
}

interface SystemPersistent extends(Persistent(Data, ApiTokenOwner)) {
  # The specialization of `Persistent` used in the "Sandstorm internal" realm, which is the realm
  # used by Sandstorm system components talking to each other. This realm is NOT seen by Sandstorm
  # applications; each grain is its own realm, and the Supervisor performs translations
  # transparently.
  #
  # In the Sandstorm internal realm, the type of SturdyRefs themselves is simply `Data`, where the
  # data is an API token. The SHA-256 hash of this token is an ID into the `ApiTokens` collection.
  # The token itself is arbitrary random bytes, not ASCII text (this differs from API tokens
  # created for the purpose of HTTP APIs).

  addRequirements @0 (requirements :List(MembraneRequirement)) -> (cap :SystemPersistent);
  # Returns a new version of this same capability with the given requirements added to the
  # conditions under which the capability may be revoked. Usually, the caller then calls `save()`
  # on the new capability.
}

interface PersistentHandle extends(SystemPersistent, Util.Handle) {}

interface PersistentOngoingNotification extends(SystemPersistent, Grain.OngoingNotification) {}

struct ApiTokenOwner {
  # Defines who is permitted to use a particular API token.

  union {
    webkey @0 :Void;
    # This API token is for use on "the web", with no specific owner. This is the kind of token
    # that you get when you use the Sandstorm UI to create a webkey.
    #
    # Note that a webkey CANNOT be directly restored by an app, since this would break confinement
    # (an app could be shipped with a webkey baked in). Instead, the app must make a powerbox
    # request, and the user may paste in a webkey there. Apps can only restore tokens explicitly
    # owned by them.
    #
    # (HackSessionContext actually allows webkeys to be exchanged for live capabilities, but this
    # is temporary until the powerbox is built.)

    grain :group {
      # Owned by a local grain.

      grainId @1 :Text;
      # Grain ID owning the ref.

      saveLabel @2 :Util.LocalizedText;
      # As passed to `save()` in Sandstorm's Persistent interface.

      introducerUser @5 :Text;
      # The user ID (`_id` in the users table) of the user whose powerbox action caused the grain
      # to receive this token. This is the user against which the `requiredPermissions` parameter
      # to `restore()` will be checked. This field is only intended to be filled in by the
      # front-end during a powerbox request; a regular `save()` call produces a capability that
      # has no "introducer".
    }

    internet @3 :AnyPointer;
    # An owner on the public internet, who used the Cap'n Proto public internet transport to call
    # `save()` and expects it to authenticate them on later `restore()`.
    #
    # TODO(someday): Change `AnyPointer` to the type for public internet owners, once the public
    #   internet Cap'n Proto protocol is defined. (Or, do we want Sandstorm nodes to be able to
    #   nested within broader networks that aren't the internet? Hmm.)

    frontend @4 :Void;
    # Owned by the front-end, i.e. stored in its Mongo database.
  }
}

struct SupervisorObjectId(AppObjectId) {
  # Refers to some persistent object which the Supervisor for a particular grain knows how to
  # restore.

  union {
    appRef @0 :AppObjectId;
    # A reference restorable by the app.

    wakeLockNotification @1 :UInt32;
    # This refers to an OngoingNotification for a wake lock. Note that although the app itself
    # implements an `OngoingNotification`, the supervisor wraps it in order to detect the `cancel`
    # call.
  }
}
